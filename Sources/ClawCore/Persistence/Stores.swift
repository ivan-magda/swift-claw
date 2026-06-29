import Foundation

public protocol AllowlistStore: Sendable {
  func seedAllowlist(userIds: [Int64]) throws
  func allowlistContains(userId: Int64) throws -> Bool
  func allowlistCount() throws -> Int
}

public protocol ProcessedUpdateStore: Sendable {
  /// INSERT OR IGNORE → true if newly claimed, false if already seen.
  /// Synchronous: no await may span the check, so the dedup claim can't interleave.
  func claimUpdate(updateId: Int64) throws -> Bool
}

public struct StopCommandResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let sessionId: Int64?
  public let cancelledRunId: Int64?

  public init(newlyClaimed: Bool, sessionId: Int64?, cancelledRunId: Int64?) {
    self.newlyClaimed = newlyClaimed
    self.sessionId = sessionId
    self.cancelledRunId = cancelledRunId
  }
}

public struct NewCommandResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let sessionId: Int64?
  public let supersededRunIds: [Int64]

  public init(newlyClaimed: Bool, sessionId: Int64?, supersededRunIds: [Int64]) {
    self.newlyClaimed = newlyClaimed
    self.sessionId = sessionId
    self.supersededRunIds = supersededRunIds
  }
}

public protocol CommandStore: Sendable {
  /// Atomic `/stop`: claim update + resolve session + RUNNING→CANCELLED + audit in one write.
  func applyStop(updateId: Int64, sessionKey: String, now: Date) throws -> StopCommandResult

  /// Atomic `/new`: claim update + resolve session + RUNNING/PENDING→SUPERSEDED +
  /// resetWindowAndDetaint + audit in one write.
  func applyNew(updateId: Int64, sessionKey: String, now: Date) throws -> NewCommandResult
}

public struct MemoryCommandResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let item: MemoryItem?

  public init(newlyClaimed: Bool, item: MemoryItem?) {
    self.newlyClaimed = newlyClaimed
    self.item = item
  }
}

public protocol MemoryStore: Sendable {
  func append(_ newItem: NewMemoryItem, now: Date) throws -> MemoryItem
  func list(kind: MemoryKind?, limit: Int) throws -> [MemoryItem]
  func get(id: Int64) throws -> MemoryItem?
  func delete(id: Int64) throws -> Bool
  func fetchRanked(excludeSensitive: Bool, limit: Int) throws -> [MemoryItem]
}

public protocol MemoryCommandStore: Sendable {
  /// Atomic confirmed remember: claim update + insert memory item + audit in one write.
  func applyRemember(
    updateId: Int64,
    item: NewMemoryItem,
    now: Date
  ) throws -> MemoryCommandResult

  /// Atomic confirmed delete: claim update + hard-delete memory item + audit in one write.
  func applyForget(updateId: Int64, itemId: Int64, now: Date) throws -> MemoryCommandResult
}

public protocol Retriever: Sendable {
  func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    limit: Int
  ) throws -> [RecallHit]
}

public protocol UpdateCursorStore: Sendable {
  func loadCursor() throws -> Int64?
  func advanceCursor(to updateId: Int64) throws
}

public protocol SessionMessageStore: Sendable {
  func loadOrCreateSession(sessionKey: String, now: Date) throws -> Int64
  /// Fused transaction: claim the update, upsert the session, insert the user message, create the
  /// PENDING run, and stamp its trigger message in one write. Duplicates create nothing.
  func claimAndPersistInbound(_ inbound: InboundMessage) throws -> ClaimResult
  /// Context returned oldest-first and bounded to the message this run is answering.
  func loadContext(
    sessionId: Int64,
    throughMessageId: Int64,
    limit: Int
  ) throws -> [StoredMessage]
  /// Advances the `/new` context boundary to the latest message and clears session taint.
  func resetWindowAndDetaint(sessionId: Int64, now: Date) throws
}

public protocol RunStore: Sendable {
  /// PENDING → RUNNING through `RunFSM`; false means the run is absent or no longer pending.
  func pickUp(runId: Int64, now: Date) throws -> Bool
  /// F6 atomicity: assistant message + run→DONE + provider_usage + outbox chunk(s) in ONE txn,
  /// committed before any send. If cancellation/supersede already won, records usage only.
  func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws -> RunCommitResult
  /// Failure/degradation commit: provider_usage + run→FAILED + degradation outbox in ONE txn.
  /// If cancellation/supersede already won, records usage when present but writes no reply.
  func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws -> RunCommitResult
  /// RUNNING → FAILED through `RunFSM`; no-ops unless the run is RUNNING.
  func failRun(runId: Int64, now: Date) throws
  /// Terminates the current RUNNING turn for `/stop`; returns the affected run, if any.
  func cancelActiveRun(sessionId: Int64, reason: CancelReason, now: Date) throws -> Int64?
  /// Terminates RUNNING and queued PENDING turns for `/new`.
  func supersedeSessionRuns(sessionId: Int64, now: Date) throws -> [Int64]
  /// Boot sweep: fail every orphaned PENDING/RUNNING run and enqueue degradation when needed.
  func reconcileRunsAtBoot(now: Date, degradationText: String) throws -> [DegradationReply]
  /// Snapshot of run-table health: in-flight count, age of oldest running run, last
  /// success/failure timestamps, and count of consecutive failures at the head of the table.
  func runsHealth(now: Date) throws -> RunsHealth
}

public protocol UsageStore: Sendable {
  func recordUsage(_ usage: ProviderUsage) throws
  /// Running totals over `provider_usage` for the calendar-day-UTC window containing `now` (D4).
  func todayTokensAndCost(now: Date) throws -> (tokens: Int, costUSD: Double)
  /// Count of `provider_usage` rows per `CostSource` in the calendar-day-UTC window (for doctor).
  func costSourceMix(now: Date) throws -> [CostSource: Int]
}

public protocol OutboxStore: Sendable {
  func claimOutbound(
    runId: Int64,
    stepIndex: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String
  ) throws -> Bool
  /// Claims a degradation reply only while the owning run is still RUNNING.
  func claimOutboundIfRunActive(
    runId: Int64,
    stepIndex: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String
  ) throws -> Bool
  func markSent(runId: Int64, stepIndex: Int, telegramMessageId: Int64, now: Date) throws
  func pendingOutbound() throws -> [OutboxRow]
}

public protocol AuditLog: Sendable {
  func appendAudit(_ event: AuditEvent) throws
}
