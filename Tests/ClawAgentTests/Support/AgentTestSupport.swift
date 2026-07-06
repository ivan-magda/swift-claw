import ClawWorkspace
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

// MARK: - Test doubles

/// Counts typing pulses so "issued at least once" and "never issued" are both observable.
actor RecordingTyping: TypingIndicator {
  private(set) var calls = 0

  func sendTyping(chatId: Int64) async {
    calls += 1
  }
}

/// Returns a scripted response or throws a scripted `ProviderError`;
/// records its call count so the preflight-stop path can assert the provider was never reached.
actor StubProvider: LLMProvider {
  enum Outcome: Sendable {
    case respond(ChatResponse)
    case fail(ProviderError)
  }

  private let outcome: Outcome
  private(set) var calls = 0

  init(_ outcome: Outcome) {
    self.outcome = outcome
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    calls += 1
    switch outcome {
    case .respond(let response): return response
    case .fail(let error): throw error
    }
  }
}

/// Never returns within the deadline: sleeps an hour so the injected no-op `sleep` lets the
/// wall-clock deadline win the race deterministically.
actor HangingProvider: LLMProvider {
  private(set) var calls = 0

  func complete(request: ChatRequest) async throws -> ChatResponse {
    calls += 1
    try await Task.sleep(for: .seconds(3600))
    return ChatResponse(content: "late", finishReason: "stop", usage: .zero, costFromProvider: nil)
  }
}

/// A one-shot release signal: `complete` blocks on `awaitRelease` until `release` is called once.
/// Lets a test pin the provider-after-typing ordering that `withTypingAndDeadline` would otherwise
/// leave to scheduler luck (the source of the historical `typing.calls` flake).
actor TypingReleaseGate {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false

  func awaitRelease() async {
    if released { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    guard !released else { return }
    released = true
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
  }
}

/// A typing indicator that releases `gate` on its first pulse, so a `GatedProvider` cannot answer
/// before the user has seen "typing…" — making "typing was issued" deterministic.
actor GatingTyping: TypingIndicator {
  private(set) var calls = 0
  private let gate: TypingReleaseGate

  init(gate: TypingReleaseGate) {
    self.gate = gate
  }

  func sendTyping(chatId: Int64) async {
    calls += 1
    await gate.release()
  }
}

/// A provider whose `complete` blocks until `gate` is released (i.e. until typing has fired once).
actor GatedProvider: LLMProvider {
  private let gate: TypingReleaseGate
  private let response: ChatResponse

  init(gate: TypingReleaseGate, response: ChatResponse) {
    self.gate = gate
    self.response = response
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    await gate.awaitRelease()
    return response
  }
}

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

/// Usage store recording rows; can throw a scripted error on the Nth write. A lock-guarded class,
/// not an actor: `UsageStore` is a synchronous (non-`async`) protocol, mirroring production
/// `UsageStoreGRDB` — a `Sendable` value type whose thread safety comes from GRDB's writer, not
/// actor isolation. An actor cannot satisfy a synchronous protocol requirement without crossing
/// into isolated state, which Swift 6 strict concurrency now flags at the conformance itself.
final class RecordingUsageStore: UsageStore, @unchecked Sendable {
  private let lock = NSLock()
  private var _recorded: [ProviderUsage] = []
  private let failOnWrite: Int?
  private let thrown: any Error

  var recorded: [ProviderUsage] {
    lock.lock()
    defer { lock.unlock() }
    return _recorded
  }

  init(failOnWrite: Int? = nil, thrown: any Error = StoreError.unexpected("scripted")) {
    self.failOnWrite = failOnWrite
    self.thrown = thrown
  }

  func recordUsage(_ usage: ProviderUsage) throws {
    lock.lock()
    defer { lock.unlock() }
    if let failOnWrite, _recorded.count + 1 == failOnWrite {
      throw thrown
    }
    _recorded.append(usage)
  }

  func todayTokensAndCost(now: Date) throws -> (tokens: Int, costUSD: Double) {
    (0, 0)
  }

  func todayTokensAndCost(
    origins: [RunOrigin],
    now: Date
  ) throws -> (tokens: Int, costUSD: Double) {
    (0, 0)
  }

  func costSourceMix(now: Date) throws -> [CostSource: Int] {
    [:]
  }
}

/// Audit log recording events; can throw a scripted error on every write. Lock-guarded, not an
/// actor, for the same reason as `RecordingUsageStore`.
final class RecordingAuditLog: AuditLog, @unchecked Sendable {
  private let lock = NSLock()
  private var _events: [AuditEvent] = []
  private let thrown: (any Error)?

  var events: [AuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return _events
  }

  init(thrown: (any Error)? = nil) {
    self.thrown = thrown
  }

  func appendAudit(_ event: AuditEvent) throws {
    lock.lock()
    defer { lock.unlock() }
    if let thrown {
      throw thrown
    }
    _events.append(event)
  }
}

/// A workspace with nothing on disk: every file load is `.missing`, no skills. Stands in for
/// `ContextBuilder` collaborators in tests that only care about history rendering.
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

/// A memory store with nothing stored: `fetchRanked` always returns empty, other members are
/// unused by history-rendering tests.
struct EmptyMemoryStore: MemoryStore {
  func append(_ newItem: NewMemoryItem, now: Date) throws -> MemoryItem {
    throw StoreError.unexpected("not used")
  }

  func list(kind: MemoryKind?, limit: Int) throws -> [MemoryItem] { [] }
  func get(id: Int64) throws -> MemoryItem? { nil }
  func delete(id: Int64) throws -> Bool { false }
  func fetchRanked(excludeSensitive: Bool, limit: Int) throws -> [MemoryItem] { [] }
}

/// A retriever with no recall corpus: always returns no hits.
struct EmptyRetriever: Retriever {
  func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    limit: Int
  ) throws -> [RecallHit] { [] }
}

// MARK: - Builders

/// A real sleep honoring the requested duration — the default so an instant provider wins the
/// race and the deadline never fires. The deadline test overrides it with `{ _ in }`.
let realSleep: @Sendable (Duration) async throws -> Void = { duration in
  try await Task.sleep(for: duration)
}

func makeCostResolver(
  priceTable: PriceTable = .empty,
  referenceUSDPerToken: Double = RunBudget.default.referenceUSDPerToken
) -> CostResolver {
  CostResolver(priceTable: priceTable, referenceUSDPerToken: referenceUSDPerToken)
}

func makeRuntime(
  provider: any LLMProvider,
  typing: any TypingIndicator = RecordingTyping(),
  drafts: any RichDraftStreaming = NoopRichDraftStreaming(),
  costResolver: CostResolver = makeCostResolver(),
  budget: RunBudget = .default,
  model: String = "gpt-4o",
  streamingEnabled: Bool = false,
  toolDispatcher: (any ToolDispatching)? = nil,
  usageStore: any UsageStore = RecordingUsageStore(),
  auditLog: any AuditLog = RecordingAuditLog(),
  sleep: @escaping @Sendable (Duration) async throws -> Void = realSleep
) -> AgentRuntime {
  AgentRuntime(
    provider: provider,
    typingIndicator: typing,
    draftStreamer: drafts,
    streamingEnabled: streamingEnabled,
    costResolver: costResolver,
    budget: budget,
    model: model,
    toolDispatcher: toolDispatcher,
    usageStore: usageStore,
    auditLog: auditLog,
    sleep: sleep
  )
}

func requireCompleted(
  _ result: TurnResult
) throws -> (content: String, usage: ProviderUsage) {
  guard case .completed(let content, let usage) = result else {
    struct Mismatch: Error, CustomStringConvertible {
      let result: TurnResult
      var description: String { "expected TurnResult.completed, got \(result)" }
    }
    throw Mismatch(result: result)
  }
  return (content, usage)
}

func requireDegraded(
  _ result: TurnResult
) throws -> (kind: DegradationKind, usage: ProviderUsage?) {
  guard case .degraded(let kind, let usage) = result else {
    struct Mismatch: Error, CustomStringConvertible {
      let result: TurnResult
      var description: String { "expected TurnResult.degraded, got \(result)" }
    }
    throw Mismatch(result: result)
  }
  return (kind, usage)
}

func userMessage(_ content: String) -> StoredMessage {
  StoredMessage(role: .user, content: content, provenance: .trusted)
}

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

func makeBuildResult(hasPrivateDataAccess: Bool = false) -> BuildResult {
  BuildResult(
    messages: [ChatMessage(role: .user, content: "go")],
    ownerNotices: [],
    hasPrivateDataAccess: hasPrivateDataAccess
  )
}
