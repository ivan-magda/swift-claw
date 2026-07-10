import ClawAgent
import ClawCore
import ClawWorkspace
import Foundation

// MARK: - Agent doubles

// Mirrors of the `ClawAgentTests` doubles (same shapes/behavior). Test targets cannot import each
// other's sources, so the agentic-loop collaborators are duplicated here for `TurnRunner` tests.

/// Scripted multi-round-trip provider: returns responses in order; records every request.
actor SequenceProvider: LLMProvider {
  private var responses: [ChatResponse]
  private(set) var requests: [ChatRequest] = []

  init(_ responses: [ChatResponse]) {
    self.responses = responses
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    requests.append(request)
    guard responses.isEmpty == false else {
      throw ProviderError.terminal(status: nil, message: "unscripted round-trip")
    }
    return responses.removeFirst()
  }
}

/// Scripted tool dispatcher: name → outcome factory; records every dispatched call+context.
actor ScriptedDispatcher: ToolDispatching {
  struct Record: Sendable {
    let call: ToolCall
    let context: ToolDispatchContext
  }

  nonisolated let definitions: [ToolDefinition]
  private let respond: @Sendable (ToolCall, ToolDispatchContext) -> ToolDispatchOutcome
  private(set) var records: [Record] = []

  init(
    definitions: [ToolDefinition] = [],
    respond: @escaping @Sendable (ToolCall, ToolDispatchContext) -> ToolDispatchOutcome
  ) {
    self.definitions = definitions
    self.respond = respond
  }

  func dispatch(call: ToolCall, context: ToolDispatchContext) async -> ToolDispatchOutcome {
    records.append(Record(call: call, context: context))
    return respond(call, context)
  }
}

// MARK: - Response/outcome builders

func okResponse(
  content: String = "Hello there",
  finishReason: String = "stop",
  usage: ChatUsage? = ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
  costFromProvider: Double? = 0.0021
) -> ChatResponse {
  ChatResponse(
    content: content,
    finishReason: finishReason,
    usage: usage,
    costFromProvider: costFromProvider
  )
}

func okOutcome(
  content: String = "ok",
  ingestedUntrusted: Bool = true,
  readPrivateData: Bool = false
) -> @Sendable (ToolCall, ToolDispatchContext) -> ToolDispatchOutcome {
  { call, _ in
    ToolDispatchOutcome(
      observation: ToolObservation(
        callId: call.id,
        toolName: call.name,
        content: content,
        status: .ok,
        ingestedUntrusted: ingestedUntrusted,
        readPrivateData: readPrivateData
      ),
      argsRedacted: call.argumentsJSON
    )
  }
}

func toolCallResponse(_ calls: [ToolCall], content: String = "") -> ChatResponse {
  ChatResponse(
    content: content,
    finishReason: "tool_calls",
    usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
    costFromProvider: nil,
    toolCalls: calls
  )
}

func fetchProposal(id: String = "c1", url: String = "https://example.com/a") -> ToolCall {
  ToolCall(id: id, name: "web_fetch", argumentsJSON: "{\"url\":\"\(url)\"}")
}

// MARK: - Empty context collaborators

/// A workspace with nothing on disk: every file load is `.missing`, no skills.
struct EmptyWorkspace: WorkspaceReading {
  func load(file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile {
    LoadedFile(outcome: .missing, text: "", graphemeCount: 0)
  }

  func loadDailyLog(day: String, maxGraphemes: Int?) -> LoadedFile {
    LoadedFile(outcome: .missing, text: "", graphemeCount: 0)
  }

  func scanSkills() -> SkillScanResult {
    SkillScanResult(descriptors: [], warnings: [])
  }
}

/// A memory store with nothing stored: `fetchRanked` always returns empty.
struct EmptyMemoryStore: MemoryStore {
  func append(_ newItem: NewMemoryItem, now: Date) throws(StoreError) -> MemoryItem {
    throw StoreError.unexpected("not used")
  }

  func list(kind: MemoryKind?, limit: Int) throws(StoreError) -> [MemoryItem] { [] }
  func get(id: Int64) throws(StoreError) -> MemoryItem? { nil }
  func delete(id: Int64) throws(StoreError) -> Bool { false }
  func fetchRanked(excludeSensitive: Bool, limit: Int) throws(StoreError) -> [MemoryItem] { [] }
}

/// A retriever with no recall corpus: always returns no hits.
struct EmptyRetriever: Retriever {
  func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    limit: Int
  ) throws(StoreError) -> [RecallHit] { [] }
}

/// A `ContextBuilder` over the empty collaborators: assembles the trigger-bounded history with no
/// workspace files, memory items, or recall hits — enough to drive `TurnRunner` end to end.
func makeEmptyContextBuilder() -> ContextBuilder {
  ContextBuilder(
    systemPrompt: SystemPrompt.minimal,
    workspace: EmptyWorkspace(),
    memoryStore: EmptyMemoryStore(),
    retriever: EmptyRetriever(),
    budget: .default,
    now: { Date(timeIntervalSince1970: 0) }
  )
}

/// Audit log recording events; lock-guarded, not an actor (the protocol is synchronous).
/// Mirror of the `ClawAgentTests` double of the same name.
final class RecordingAuditLog: AuditLog, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [AuditEvent] = []

  var events: [AuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func appendAudit(_ event: AuditEvent) throws(StoreError) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(event)
  }
}
