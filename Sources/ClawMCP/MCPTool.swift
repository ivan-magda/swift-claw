import ClawCore
import Foundation
import Logging
import MCP

/// One remote tool, wearing the local `Tool` contract.
///
/// The adapter is deliberately thin: the gate, the approval FSM, the redactor, and the audit trail
/// all treat an MCP tool exactly as they treat a built-in, so everything that makes a remote tool
/// different is expressed as declarations rather than as special cases elsewhere.
///
/// Two of those declarations are not negotiable per tool. Egress is always
/// `.arbitraryDestination`: the arguments go to a third-party server that decides what to do with
/// them, which is the widest sink we model. And every result is `ingestedUntrusted`, because a
/// remote server's text is exactly the untrusted-input case the trifecta gate exists for. The tier
/// is the one thing the owner may relax, and only downward to `.safe`.
public struct MCPTool: ClawCore.Tool {
  /// Head-room over the server's own worst case (reconnect plus call). `execute` therefore always
  /// returns before the dispatcher's abandon-race fires, which is what keeps the approved-execution
  /// path — a direct await with no race of its own — bounded.
  public static let timeoutMarginSeconds = 5

  private let resolved: ResolvedMCPTool
  private let session: MCPServerSession
  private let redactor: SecretRedactor
  private let outputCapGraphemes: Int
  private let logger: Logger

  public init(
    resolved: ResolvedMCPTool,
    session: MCPServerSession,
    redactor: SecretRedactor,
    outputCapGraphemes: Int = ToolOutputCap.maxGraphemes,
    logger: Logger = Logger(label: "claw.mcp.tool")
  ) {
    self.resolved = resolved
    self.session = session
    self.redactor = redactor
    self.outputCapGraphemes = outputCapGraphemes
    self.logger = logger
  }

  public var definition: ToolDefinition {
    let sanitizer = MCPMetadataSanitizer(redactor: redactor)
    return ToolDefinition(
      name: resolved.localName,
      description: sanitizer.text(resolved.description),
      parameters: sanitizer.schema(resolved.parameters),
      egressClass: .arbitraryDestination,
      riskLevel: resolved.riskLevel,
      invocationIdentity: invocationIdentity
    )
  }

  public var timeout: Duration {
    .seconds(config.worstCaseCallSeconds + Self.timeoutMarginSeconds)
  }

  /// The server, never a destination read out of the arguments. An MCP call has exactly one
  /// recipient — the one the owner configured — so the approval binds to that, and a model that
  /// stuffs a URL into an argument cannot make the prompt say something else.
  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    .resolved(target)
  }

  public func approvalPresentation(
    arguments: JSONValue,
    canonicalTarget: String
  ) -> ToolApprovalPresentation {
    ToolApprovalPresentation(
      blastRadius:
        "MCP: \(config.name) · "
        + MCPMetadataSanitizer(redactor: redactor).displayName(resolved.coordinate.remoteName),
      contentPreview: preview(of: arguments),
      warnings: []
    )
  }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    guard canonicalTarget == target else {
      return localFailure("\(resolved.localName) was not sent because its approved target changed.")
    }
    guard let payload = arguments.objectValue else {
      return localFailure("\(resolved.localName) needs a JSON object of arguments.")
    }

    do {
      let result = try await session.callTool(
        name: resolved.coordinate.remoteName,
        arguments: payload
      )
      return remoteResult(result)
    } catch {
      logger.debug(
        "MCP tool call failed",
        metadata: [
          "server": .string(config.name),
          "tool": .string(resolved.coordinate.remoteName),
          "error": .string("\(error)"),
        ]
      )
      return localFailure(failureText(error))
    }
  }
}

// MARK: - Identity

private extension MCPTool {
  var config: MCPServerConfig { session.config }

  /// Names the server and its complete endpoint: scheme, port, path, and query can each select a
  /// different recipient, so a host-only label is not an exact-action binding.
  var target: String {
    "\(config.name) (\(config.url.absoluteString))"
  }

  var invocationIdentity: String {
    let identity = JSONValue.object([
      "endpoint": .string(config.url.absoluteString),
      "remoteTool": .string(resolved.coordinate.remoteName),
    ])
    return CanonicalJSON.encode(identity)
      ?? "\(config.url.absoluteString)\n\(resolved.coordinate.remoteName)"
  }

  func preview(of arguments: JSONValue) -> String? {
    guard let rendered = CanonicalJSON.encode(arguments) else {
      return nil
    }
    return ToolOutputCap.cap(
      redactor.redact(rendered),
      maxGraphemes: ToolOutputCap.approvalPreviewGraphemes
    )
  }
}

// MARK: - Payloads

private extension MCPTool {
  /// A result from the server, whether it reports success or its own failure. Both carry remote
  /// text, so both are untrusted; the server saying "that failed" is still the server talking.
  func remoteResult(_ result: MCPToolCallResult) -> ToolPayload {
    ToolPayload(
      content: ToolOutputCap.cap(
        redactor.redact(Self.render(result)),
        maxGraphemes: outputCapGraphemes
      ),
      status: result.isError ? .error : .ok,
      ingestedUntrusted: true
    )
  }

  /// Our own words about a call that never produced a result. Nothing here is server-authored, so
  /// nothing here taints the turn.
  func localFailure(_ reason: String) -> ToolPayload {
    ToolPayload(content: reason, status: .error, ingestedUntrusted: false)
  }

  /// Only our own error vocabulary is rendered. An SDK or server-authored error can quote remote
  /// text, and a message that reads as ours must not be written by a third party — so anything
  /// unrecognized collapses to a generic line and the detail goes to the log instead.
  func failureText(_ error: any Error) -> String {
    let detail: String
    switch error {
    case let transport as MCPTransportError:
      detail = "\(transport)"
    case let session as MCPSessionError:
      detail = "\(session)"
    case is CancellationError:
      detail = "the call was cancelled"
    default:
      detail = "the server did not complete the call"
    }

    return "\(resolved.localName) failed: \(detail)."
  }
}

// MARK: - Content rendering

private extension MCPTool {
  /// The content array is the compatibility representation and wins when present. A server may
  /// return structured content alone, in which case its canonical JSON becomes the observation.
  static func render(_ result: MCPToolCallResult) -> String {
    guard result.content.isEmpty else {
      return render(result.content)
    }
    guard let structured = result.structuredContent else {
      return ""
    }
    return CanonicalJSON.encode(structured) ?? ""
  }

  /// Text parts join as text; everything else is noted by kind, because the model can act on
  /// knowing a picture came back even though it cannot see one.
  static func render(_ content: [MCP.Tool.Content]) -> String {
    content
      .map(part)
      .joined(separator: "\n")
  }

  static func part(_ content: MCP.Tool.Content) -> String {
    switch content {
    case .text(let text, _, _):
      return text
    case .image(_, let mimeType, _, _):
      return "[image: \(mimeType)]"
    case .audio(_, let mimeType, _, _):
      return "[audio: \(mimeType)]"
    case .resource(let resource, _, _):
      guard let text = resource.text else {
        return "[resource: \(resource.uri) (\(resource.mimeType ?? "binary"))]"
      }
      return text
    case .resourceLink(let uri, let name, _, _, _, _):
      return "[resource link: \(name) at \(uri)]"
    }
  }
}
