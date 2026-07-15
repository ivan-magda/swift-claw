import ClawCore
import Foundation

// MARK: - Providers

/// Scripted multi-round-trip provider: returns responses in order; records every request.
public actor SequenceProvider: LLMProvider {
  private var responses: [ChatResponse]
  public private(set) var requests: [ChatRequest] = []

  public init(_ responses: [ChatResponse]) {
    self.responses = responses
  }

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    requests.append(request)
    guard responses.isEmpty == false else {
      throw ProviderError.terminal(status: nil, message: "unscripted round-trip")
    }
    return responses.removeFirst()
  }
}

/// Never returns within the deadline: sleeps an hour so the injected no-op `sleep` lets the
/// wall-clock deadline win the race deterministically. The post-sleep throw is unreachable under
/// an injected clock (the sleep is cancelled) and only names the brownout it stands in for.
public struct HangingProvider: LLMProvider {
  public init() {}

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    try await Task.sleep(for: .seconds(3600))
    throw ProviderError.terminal(status: nil, message: "unreachable")
  }
}

// MARK: - Provider call identity

/// Mints `call-1`, `call-2`, … in call order, so a test can name the identity a given round-trip
/// records instead of matching a random UUID. Lock-guarded, not an actor:
/// `ProviderCallIDGenerating` is synchronous, mirroring the live `UUIDProviderCallIDGenerator` —
/// a value type needing no coordination — and an actor cannot satisfy a synchronous requirement.
public final class SequentialCallIDGenerator: ProviderCallIDGenerating, @unchecked Sendable {
  private let lock = NSLock()
  private let prefix: String
  private var issued = 0

  public init(prefix: String = "call") {
    self.prefix = prefix
  }

  public func next() -> ProviderCallID {
    lock.lock()
    defer { lock.unlock() }
    issued += 1
    return ProviderCallID(rawValue: "\(prefix)-\(issued)")
  }
}

// MARK: - Dispatcher

/// Scripted tool dispatcher: name → outcome factory; records every dispatched call+context.
public actor ScriptedDispatcher: ToolDispatching {
  public struct Record: Sendable {
    public let call: ToolCall
    public let context: ToolDispatchContext
  }

  nonisolated public let definitions: [ToolDefinition]
  private let respond: @Sendable (ToolCall, ToolDispatchContext) -> ToolDispatchOutcome
  public private(set) var records: [Record] = []

  public init(
    definitions: [ToolDefinition] = [],
    respond: @escaping @Sendable (ToolCall, ToolDispatchContext) -> ToolDispatchOutcome
  ) {
    self.definitions = definitions
    self.respond = respond
  }

  public func dispatch(
    call: ToolCall,
    context: ToolDispatchContext
  ) async -> ToolDispatchOutcome {
    records.append(Record(call: call, context: context))
    return respond(call, context)
  }
}

// MARK: - Audit log

/// Audit log recording events; can throw a scripted error on every write. Lock-guarded, not an
/// actor: `AuditLog` is a synchronous protocol an actor cannot satisfy without crossing into
/// isolated state, which Swift 6 strict concurrency flags at the conformance itself.
public final class RecordingAuditLog: AuditLog, @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [AuditEvent] = []
  private let thrown: StoreError?

  public var events: [AuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storedEvents
  }

  public init(thrown: StoreError? = nil) {
    self.thrown = thrown
  }

  public func appendAudit(_ event: AuditEvent) throws(StoreError) {
    lock.lock()
    defer { lock.unlock() }
    if let thrown {
      throw thrown
    }
    storedEvents.append(event)
  }
}

// MARK: - Empty context collaborators

/// A workspace with nothing on disk: every file load is `.missing`, no skills. Stands in for
/// `ContextBuilder` collaborators in tests that only care about history rendering.
public struct EmptyWorkspace: WorkspaceReading {
  public init() {}

  public func load(file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile {
    LoadedFile(outcome: .missing, text: "", graphemeCount: 0)
  }

  public func loadDailyLog(day: String, maxGraphemes: Int?) -> LoadedFile {
    LoadedFile(outcome: .missing, text: "", graphemeCount: 0)
  }

  public func scanSkills() -> SkillScanResult {
    SkillScanResult(descriptors: [], warnings: [])
  }
}

/// A memory store with nothing stored: `fetchRanked` always returns empty, other members are
/// unused by history-rendering tests.
public struct EmptyMemoryStore: MemoryStore {
  public init() {}

  public func append(_ newItem: NewMemoryItem, now: Date) throws(StoreError) -> MemoryItem {
    throw StoreError.unexpected("not used")
  }

  public func list(kind: MemoryKind?, limit: Int) throws(StoreError) -> [MemoryItem] { [] }
  public func get(id: Int64) throws(StoreError) -> MemoryItem? { nil }
  public func delete(id: Int64) throws(StoreError) -> Bool { false }

  public func fetchRanked(
    excludeSensitive: Bool,
    limit: Int
  ) throws(StoreError) -> [MemoryItem] { [] }
}

/// A retriever with no recall corpus: always returns no hits.
public struct EmptyRetriever: Retriever {
  public init() {}

  public func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    limit: Int
  ) throws(StoreError) -> [RecallHit] { [] }
}
