import Foundation

/// One proposed call. `argumentsJSON` stays a raw JSON string (the wire form); the dispatcher
/// decodes it — the LLM layer never interprets arguments. Codable so exchanges persist as one
/// JSON column (`messages.tool_calls`) with the pinned shape `{"id","name","arguments"}`.
public struct ToolCall: Sendable, Equatable, Codable {
  public let id: String
  public let name: String
  public let argumentsJSON: String

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case argumentsJSON = "arguments"
  }

  public init(id: String, name: String, argumentsJSON: String) {
    self.id = id
    self.name = name
    self.argumentsJSON = argumentsJSON
  }
}

/// The single encoder/decoder for the `messages.tool_calls` column. Decode is lenient (malformed
/// history must never crash rendering — the renderer's orphan guard handles the fallout).
public enum ToolCallCoding {
  public static func encode(_ calls: [ToolCall]) -> String? {
    let encoder = JSONEncoder()
    // Persist URLs/paths in their natural form (`/`, not `\/`) so the stored anchor reads as the
    // model proposed it — decode is symmetric either way, but the escaped form is gratuitous.
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(calls) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  public static func decode(_ json: String) -> [ToolCall] {
    (try? JSONDecoder().decode([ToolCall].self, from: Data(json.utf8))) ?? []
  }
}

/// A minimal JSON value tree — parameter schemas and decoded arguments. ClawCore has no I/O
/// deps, so this small enum stands in for any JSON library.
public indirect enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case integer(Int)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

extension JSONValue {
  public static func == (left: JSONValue, right: JSONValue) -> Bool {
    switch (left, right) {
    case (.null, .null):
      return true
    case (.bool(let leftValue), .bool(let rightValue)):
      return leftValue == rightValue
    case (.integer(let leftValue), .integer(let rightValue)):
      return leftValue == rightValue
    case (.number(let leftValue), .number(let rightValue)):
      return leftValue == rightValue
    case (.integer(let integer), .number(let number)), (.number(let number), .integer(let integer)):
      return Int(exactly: number) == integer
    case (.string(let leftValue), .string(let rightValue)):
      return leftValue == rightValue
    case (.array(let leftValue), .array(let rightValue)):
      return leftValue == rightValue
    case (.object(let leftValue), .object(let rightValue)):
      return leftValue == rightValue
    default:
      return false
    }
  }
}

extension JSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let boolValue = try? container.decode(Bool.self) {
      self = .bool(boolValue)
    } else if let integerValue = try? container.decode(Int.self) {
      self = .integer(integerValue)
    } else if let numberValue = try? container.decode(Double.self) {
      self = .number(numberValue)
    } else if let stringValue = try? container.decode(String.self) {
      self = .string(stringValue)
    } else if let arrayValue = try? container.decode([JSONValue].self) {
      self = .array(arrayValue)
    } else if let objectValue = try? container.decode([String: JSONValue].self) {
      self = .object(objectValue)
    } else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unsupported JSON")
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let boolValue):
      try container.encode(boolValue)
    case .integer(let integerValue):
      try container.encode(integerValue)
    case .number(let numberValue):
      try container.encode(numberValue)
    case .string(let stringValue):
      try container.encode(stringValue)
    case .array(let arrayValue):
      try container.encode(arrayValue)
    case .object(let objectValue):
      try container.encode(objectValue)
    }
  }
}

extension JSONValue {
  /// Parses a raw JSON string (tool `argumentsJSON`); nil on malformed input.
  public static func parse(_ json: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
  }

  // nil means "not an object" — distinct from `.object([:])`, so an empty default would lie.
  // swiftlint:disable:next discouraged_optional_collection
  public var objectValue: [String: JSONValue]? {
    guard case .object(let objectValue) = self else {
      return nil
    }
    return objectValue
  }

  public var stringValue: String? {
    guard case .string(let stringValue) = self else {
      return nil
    }
    return stringValue
  }

  public var numberValue: Double? {
    switch self {
    case .integer(let integerValue):
      return Double(integerValue)
    case .number(let numberValue):
      return numberValue
    case .null, .bool, .string, .array, .object:
      return nil
    }
  }
}

/// How a tool's arguments can leave the machine (the sink classification). Declared on the
/// contract — with no default — so a new tool cannot compile without classifying itself; the
/// gate consumes this declaration instead of a name set, making a forgotten classification a
/// compile error rather than a silent arg-guard bypass.
public enum ToolEgressClass: Sendable, Equatable {
  /// Nothing egresses (file_read): args are redaction-RENDERED for audit only.
  case none
  /// Args egress to one owner-pinned endpoint (web_search): the blocking arg-guard tiers apply;
  /// no per-target approval exists because the destination is fixed at composition.
  case fixedEndpoint
  /// Args choose the destination (web_fetch): arg-guard tiers plus the trifecta approval, keyed
  /// on the canonical target resolved via `Tool.canonicalTarget(arguments:)`.
  case arbitraryDestination
}

/// The outcome of resolving an `.arbitraryDestination` tool's target: the canonical form the
/// gate authorizes (and hands into `execute`), or the owner-facing refusal copy (URL policy,
/// missing argument).
public enum CanonicalTargetResolution: Sendable, Equatable {
  case resolved(String)
  case refused(reason: String)
}

/// The declared risk tier the gate enforces: `safe` executes untapped, `ask` requires a
/// per-action durable approval, `dangerous` is refused unless explicitly config-enabled.
/// No default anywhere — a new tool cannot
/// compile without classifying itself, mirroring `ToolEgressClass`.
public enum RiskLevel: String, Sendable, Equatable {
  case safe
  case ask
  case dangerous
}

/// What the registry advertises to the provider (wire `tools` entry).
public struct ToolDefinition: Sendable, Equatable {
  public let name: String
  public let description: String
  public let parameters: JSONValue  // JSON-Schema object
  /// Trust of the provider-facing name, description, and schema. External metadata reaches the
  /// model before any tool result exists, so the runtime uses this provenance to arm taint before
  /// the first provider call.
  public let metadataProvenance: Provenance
  /// The declared policy class the gate enforces. NOT advertised on the wire.
  public let egressClass: ToolEgressClass
  /// The declared risk tier (orthogonal to egress). NOT advertised on the wire.
  public let riskLevel: RiskLevel
  /// The untrusted-fence label this tool's output renders under, defaulting to the tool's name.
  /// A tool declares another label only when trusted policy already licenses that label for
  /// exactly this content — the label is what the prompt's carve-outs are written against.
  public let fenceLabel: String
  /// Credential-free execution identity used only by `policy_version` when the advertised fields do
  /// not fully identify what will run (for example, an adapter backed by a configured endpoint).
  /// NOT advertised on the wire.
  public let invocationIdentity: String?

  public init(
    name: String,
    description: String,
    parameters: JSONValue,
    metadataProvenance: Provenance,
    egressClass: ToolEgressClass,
    riskLevel: RiskLevel,
    fenceLabel: String? = nil,
    invocationIdentity: String? = nil
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.metadataProvenance = metadataProvenance

    self.egressClass = egressClass
    self.riskLevel = riskLevel
    self.fenceLabel = fenceLabel ?? name
    self.invocationIdentity = invocationIdentity
  }
}

public enum ToolObservationStatus: String, Sendable, Equatable {
  case ok
  case error  // tool failed; content = plain-language reason
  case blockedArgs = "blocked_args"  // ExfilArgGuard refusal
  case blockedSSRF = "blocked_ssrf"
  case blockedPendingApproval = "blocked_pending_approval"
}

/// What a tool returns, sans call identity — the dispatcher stamps identity.
/// `readPrivateData` is true only for a `file_read` whose canonical target is MEMORY.md/USER.md
/// (the run-local private-data signal).
public struct ToolPayload: Sendable, Equatable {
  public let content: String  // already output-capped
  public let status: ToolObservationStatus
  public let ingestedUntrusted: Bool  // true on any successful web/file read
  public let readPrivateData: Bool

  public init(
    content: String,
    status: ToolObservationStatus,
    ingestedUntrusted: Bool,
    readPrivateData: Bool = false
  ) {
    self.content = content
    self.status = status
    self.ingestedUntrusted = ingestedUntrusted
    self.readPrivateData = readPrivateData
  }
}

/// The uniform result of one dispatched call — success and failure are both observations
/// (failures-as-observations), never a thrown error crossing the loop.
public struct ToolObservation: Sendable, Equatable {
  public let callId: String
  public let toolName: String
  public let content: String
  public let status: ToolObservationStatus
  public let ingestedUntrusted: Bool
  public let readPrivateData: Bool

  public init(
    callId: String,
    toolName: String,
    content: String,
    status: ToolObservationStatus,
    ingestedUntrusted: Bool,
    readPrivateData: Bool = false
  ) {
    self.callId = callId
    self.toolName = toolName
    self.content = content
    self.status = status
    self.ingestedUntrusted = ingestedUntrusted
    self.readPrivateData = readPrivateData
  }

  public init(call: ToolCall, payload: ToolPayload) {
    self.init(
      callId: call.id,
      toolName: call.name,
      content: payload.content,
      status: payload.status,
      ingestedUntrusted: payload.ingestedUntrusted,
      readPrivateData: payload.readPrivateData
    )
  }
}

/// The tool seam. Gate checks happen BEFORE dispatch (ToolPolicyGate); an executing tool only
/// ever sees already-authorized, parsed args. Tools DECLARE their policy class
/// (`definition.egressClass`) and, for `.arbitraryDestination`, HOW to resolve the target —
/// enforcement lives exclusively in the gate.
public protocol Tool: Sendable {
  var definition: ToolDefinition { get }
  var timeout: Duration { get }

  /// The canonical, owner-visible target this call would act on — REQUIRED for
  /// `.arbitraryDestination` tools (the gate keys approvals on it and hands the resolved
  /// form to `execute`); `nil` for `.none`/`.fixedEndpoint` tools. No default implementation:
  /// every tool decides explicitly.
  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution?

  /// Resolves everything a dangerous approval must bind. The default nil is correct for safe and
  /// ask-tier tools; the gate fails closed when a dangerous tool returns nil.
  func prepareAction(arguments: JSONValue) async -> PreparedActionResolution?

  /// `canonicalTarget` is the gate-resolved form for `.arbitraryDestination` tools — act on
  /// exactly what was authorized, never re-derive it; `nil` for the other classes.
  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload

  /// The prompt inputs for an ask-tier or trifecta approval, produced at gate time on the
  /// gate-resolved `canonicalTarget`. The default is a generic egress presentation; write tools
  /// override with blast radius, a redacted preview, and any scan warnings.
  func approvalPresentation(
    arguments: JSONValue,
    canonicalTarget: String
  ) -> ToolApprovalPresentation
}

extension Tool {
  public func prepareAction(arguments: JSONValue) async -> PreparedActionResolution? {
    nil
  }

  public func approvalPresentation(
    arguments: JSONValue,
    canonicalTarget: String
  ) -> ToolApprovalPresentation {
    ToolApprovalPresentation(
      blastRadius: "egress to \(canonicalTarget)",
      contentPreview: nil,
      warnings: []
    )
  }
}

/// The search seam. One v1 impl: ExaSearchProvider.
public protocol SearchProviding: Sendable {
  func search(query: String, count: Int) async throws -> [SearchResult]
}

public struct SearchResult: Sendable, Equatable {
  public let title: String
  public let url: String
  public let snippet: String

  public init(title: String, url: String, snippet: String) {
    self.title = title
    self.url = url
    self.snippet = snippet
  }
}

/// One persisted round-trip that proposed tool calls: the assistant anchor plus its observations.
public struct ToolExchange: Sendable, Equatable {
  public let assistantContent: String  // may be "" (pure tool-call rounds)
  public let toolCalls: [ToolCall]
  public let observations: [ToolObservation]
  public let providerState: ProviderExchangeState?

  public init(
    assistantContent: String,
    toolCalls: [ToolCall],
    observations: [ToolObservation],
    providerState: ProviderExchangeState? = nil
  ) {
    self.assistantContent = assistantContent
    self.toolCalls = toolCalls
    self.observations = observations
    self.providerState = providerState
  }
}
