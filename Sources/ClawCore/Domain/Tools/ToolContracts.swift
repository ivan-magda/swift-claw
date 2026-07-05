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
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

extension JSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let boolValue = try? container.decode(Bool.self) {
      self = .bool(boolValue)
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
    guard case .number(let numberValue) = self else {
      return nil
    }
    return numberValue
  }
}

/// What the registry advertises to the provider (wire `tools` entry).
public struct ToolDefinition: Sendable, Equatable {
  public let name: String
  public let description: String
  public let parameters: JSONValue  // JSON-Schema object

  public init(name: String, description: String, parameters: JSONValue) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }
}

public enum ToolObservationStatus: String, Sendable, Equatable {
  case ok
  case error  // tool failed; content = plain-language reason
  case blockedArgs = "blocked_args"  // ExfilArgGuard refusal
  case blockedSSRF = "blocked_ssrf"
  case blockedPendingApproval = "blocked_pending_approval"
}

/// What a tool returns, sans call identity — the dispatcher stamps identity (settles spec §20-6).
/// `readPrivateData` is true only for a `file_read` whose canonical target is MEMORY.md/USER.md
/// (rev.1 H1 — the run-local private-data signal).
public struct ToolPayload: Sendable, Equatable {
  public let content: String  // already output-capped (§15)
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
/// (failures-as-observations, §19 ARCHITECTURE), never a thrown error crossing the loop.
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
/// ever sees already-authorized, parsed args.
public protocol Tool: Sendable {
  var definition: ToolDefinition { get }
  var timeout: Duration { get }

  func execute(arguments: JSONValue) async -> ToolPayload
}

/// The search seam (D2). One v1 impl: ExaSearchProvider (§7.4, research-settled).
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

  public init(assistantContent: String, toolCalls: [ToolCall], observations: [ToolObservation]) {
    self.assistantContent = assistantContent
    self.toolCalls = toolCalls
    self.observations = observations
  }
}
