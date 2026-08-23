import ClawCore
import Foundation

/// Runs one shell command on the owner's own machine, outside the sandbox. Every call starts a
/// fresh shell at the workspace root, so nothing survives a call except what it wrote to disk.
public struct BashTool: Tool {
  /// Slack over the per-call ceiling, so the launcher's own deadline is what reports a timeout
  /// and the dispatcher's is only a backstop.
  static let dispatchGrace = Duration.seconds(20)

  static let hostWarning = "this command runs on the host machine, outside the sandbox"

  let workspaceRoot: URL
  let config: BashConfig
  let redactor: SecretRedactor

  public init(workspaceRoot: URL, config: BashConfig, redactor: SecretRedactor) {
    self.workspaceRoot = workspaceRoot
    self.config = config
    self.redactor = redactor
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: "bash",
      description: """
        Run one shell command on the host machine, with its real toolchain and filesystem (owner \
        approval required). Each call is a fresh shell whose working directory is always the \
        workspace root: a `cd`, a variable, or a background job does not carry into the next \
        call, though files the command writes do.
        """,
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "command": .object([
            "type": .string("string"),
            "description": .string("The shell command line to run."),
          ]),
          "timeoutSeconds": .object([
            "type": .string("integer"),
            "description": .string("How long the command may run before it is killed."),
            "minimum": .integer(1),
            "maximum": .integer(config.maxTimeoutSeconds),
            "default": .integer(config.defaultTimeoutSeconds),
          ]),
        ]),
        "required": .array([.string("command")]),
      ]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .dangerous
    )
  }

  public var timeout: Duration {
    .seconds(config.maxTimeoutSeconds) + Self.dispatchGrace
  }

  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    nil
  }

  public func prepareAction(arguments: JSONValue) async -> PreparedActionResolution? {
    guard let raw = DangerousToolSupport.decode(RawArguments.self, from: arguments) else {
      return .refused(
        reason: "bash needs command as a string and timeoutSeconds as a whole number of seconds."
      )
    }

    let command = raw.command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard command.isEmpty == false else {
      return .refused(reason: "bash needs a command to run.")
    }

    let timeoutSeconds: Int
    switch resolveTimeout(raw.timeoutSeconds) {
    case .refused(let reason):
      return .refused(reason: reason)
    case .resolved(let resolved):
      timeoutSeconds = resolved
    }

    let recorded = RecordedArguments(command: command, timeoutSeconds: timeoutSeconds)
    guard let canonicalArgsJSON = DangerousToolSupport.canonicalJSON(recorded) else {
      return .refused(reason: "The prepared bash action could not be encoded safely.")
    }

    return .prepared(
      PreparedToolAction(
        canonicalTarget: canonicalTarget(),
        canonicalArgsJSON: canonicalArgsJSON,
        presentation: approvalPresentation(recorded: recorded),
        guardTexts: [command],
        // The host keeps its network, so any command can reach outward; the trifecta tier has to
        // assume it will.
        canExfiltrate: true
      )
    )
  }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    DangerousToolSupport.errorPayload("bash cannot run commands yet.", redactor: redactor)
  }
}

// MARK: - Argument Values

private extension BashTool {
  struct RawArguments: Decodable {
    let command: String
    let timeoutSeconds: Int?

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      command = try container.decode(String.self, forKey: .command)
      timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
    }

    private enum CodingKeys: String, CodingKey {
      case command
      case timeoutSeconds
    }
  }

  struct RecordedArguments: Codable, Equatable {
    let command: String
    let timeoutSeconds: Int
  }

  enum TimeoutResolution {
    case resolved(Int)
    case refused(String)
  }

  /// The model names the timeout it wants; the owner's ceiling is what it gets.
  func resolveTimeout(_ requested: Int?) -> TimeoutResolution {
    guard let requested else {
      return .resolved(min(config.defaultTimeoutSeconds, config.maxTimeoutSeconds))
    }
    guard requested > 0 else {
      return .refused("bash needs a timeout of at least one second.")
    }
    return .resolved(min(requested, config.maxTimeoutSeconds))
  }
}

// MARK: - Canonical Action

private extension BashTool {
  /// Every bash call acts on the same thing — one shell, one working directory — so the target
  /// pins that pair and the args hash alone distinguishes one command from the next.
  func canonicalTarget() -> String {
    "host_exec:\(config.shellPath):\(workspaceRoot.path)"
  }

  func approvalPresentation(recorded: RecordedArguments) -> ToolApprovalPresentation {
    ToolApprovalPresentation(
      blastRadius:
        "run \(config.shellPath) -c · cwd: \(workspaceRoot.path) · timeout \(recorded.timeoutSeconds)s",
      contentPreview: """
        ```bash
        \(redactor.redact(recorded.command))
        ```
        """,
      warnings: [Self.hostWarning]
    )
  }
}
