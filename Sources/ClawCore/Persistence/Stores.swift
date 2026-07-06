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

public enum CommandClaim: Sendable, Equatable {
  case duplicate
  case claimed(sessionId: Int64)
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

public struct ScheduleArmResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let job: ScheduledJob?

  public init(newlyClaimed: Bool, job: ScheduledJob?) {
    self.newlyClaimed = newlyClaimed
    self.job = job
  }
}

public protocol ScheduleCommandStore: Sendable {
  /// Atomic confirmed arm (spec §8): claim update + insert job + jobCreated audit in one write.
  /// The inserted job is the exact parked draft — the caller never re-parses (TOCTOU kill).
  func applyArm(updateId: Int64, job: NewScheduledJob, now: Date) throws -> ScheduleArmResult
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
  func claimCommandUpdate(updateId: Int64, sessionKey: String, now: Date) throws -> CommandClaim
  func findSession(sessionKey: String) throws -> Int64?
  /// Fused transaction: claim the update, upsert the session, insert the user message, create the
  /// PENDING run, and stamp its trigger message in one write. Duplicates create nothing.
  func claimAndPersistInbound(_ inbound: InboundMessage) throws -> ClaimResult
  /// Context returned oldest-first and bounded to the message this run is answering.
  func loadContext(
    sessionId: Int64,
    throughMessageId: Int64,
    limit: Int
  ) throws -> [StoredMessage]
  /// Context snapshot returned oldest-first and bounded to the message this run is answering.
  /// Includes the durable session metadata the assembler needs for recall dedup and taint reads.
  func loadContextSnapshot(
    sessionId: Int64,
    throughMessageId: Int64,
    limit: Int
  ) throws -> SessionContextSnapshot
  /// Advances the `/new` context boundary to the latest message and clears session taint.
  func resetWindowAndDetaint(sessionId: Int64, now: Date) throws
}

public protocol RunStore: Sendable {
  /// PENDING → RUNNING through `RunFSM`, returning the run's origin in the same write; nil means
  /// the run is absent or no longer pending — the guard semantics are unchanged (spec §10,
  /// preamble deviation 3: one query, no separate origin read).
  func pickUp(runId: Int64, now: Date) throws -> RunOrigin?
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
  /// Boot sweep: every PENDING/RUNNING orphan → FAILED (+ jobFailed for job runs), one
  /// degradation notice per run that never delivered. `heartbeatNoticeChatId` is the
  /// config-resolved owner DM for crashed heartbeat runs (spec §12/A6) — their synthetic
  /// session key carries no chat id; nil (heartbeat unconfigured) skips the notice only.
  func reconcileRunsAtBoot(
    now: Date,
    degradationText: String,
    heartbeatNoticeChatId: Int64?
  ) throws -> [DegradationReply]
  /// Snapshot of run-table health: in-flight count, age of oldest running run, last
  /// success/failure timestamps, and count of consecutive failures at the head of the table.
  func runsHealth(now: Date) throws -> RunsHealth
}

public protocol UsageStore: Sendable {
  func recordUsage(_ usage: ProviderUsage) throws
  /// Running totals over `provider_usage` for the calendar-day-UTC window containing `now` (D4).
  func todayTokensAndCost(now: Date) throws -> (tokens: Int, costUSD: Double)
  /// The same UTC-day window as `todayTokensAndCost(now:)`, restricted to usage whose run's
  /// origin is IN `origins` (JOIN provider_usage.run_id → runs.id — D6: no denormalized origin
  /// on usage rows). One query, one day-boundary evaluation (spec §11).
  func todayTokensAndCost(origins: [RunOrigin], now: Date) throws -> (tokens: Int, costUSD: Double)
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

public struct ClaimedFire: Sendable, Equatable {
  public let runId: Int64
  public let sessionId: Int64
  public let triggerMessageId: Int64
  public let ownerChatId: Int64

  public init(runId: Int64, sessionId: Int64, triggerMessageId: Int64, ownerChatId: Int64) {
    self.runId = runId
    self.sessionId = sessionId
    self.triggerMessageId = triggerMessageId
    self.ownerChatId = ownerChatId
  }
}

public protocol ScheduledJobStore: Sendable {
  func create(_ job: NewScheduledJob, now: Date) throws -> ScheduledJob
  func job(id: Int64) throws -> ScheduledJob?
  func listAll() throws -> [ScheduledJob]
  func dueJobs(now: Date) throws -> [ScheduledJob]  // status='ACTIVE' AND next_occurrence <= now

  /// Spec §5.2 — the whole fused transaction. `due` is the CAS predicate (the stored
  /// next_occurrence being claimed); `fireAt` is T_fire (== due on time, the latest missed
  /// occurrence when coalescing); `nextOccurrence` nil ⇒ one-shot → COMPLETED. Creates the
  /// job session on first fire (session_key = SessionKey.scheduledJob(id:)), inserts the
  /// trigger message (role user, provenance trusted, text = job prompt), the PENDING run
  /// (origin 'scheduled', job_id set), and the jobExecuted audit row — one writeMapping.
  /// Returns nil when the CAS matches no row (claimed elsewhere / job mutated): no fire.
  func claimAndFire(
    jobId: Int64,
    due: Date,
    fireAt: Date,
    nextOccurrence: Date?,
    now: Date
  ) throws -> ClaimedFire?

  /// Spec §5.4 run-now: the same fused insert set with NO schedule advance. Requires
  /// status ACTIVE or PAUSED (nil otherwise). fireAt = now; jobExecuted audited in-txn.
  func fireNow(jobId: Int64, now: Date) throws -> ClaimedFire?

  /// Spec §5.3 skip: advance next_occurrence past now with no run (nil ⇒ one-shot →
  /// COMPLETED), update scheduler_state.last_misfire_at / last_misfire_skipped_count, and
  /// audit jobMisfire — one transaction. Returns false when the job was concurrently mutated.
  func skipMisfire(
    jobId: Int64,
    due: Date,
    nextOccurrence: Date?,
    skippedCount: Int,
    now: Date
  ) throws -> Bool

  /// ACTIVE→PAUSED, idempotent.
  func pause(id: Int64, now: Date) throws -> ScheduledJob?
  /// PAUSED→ACTIVE; the caller recomputes next_occurrence from now.
  func resume(id: Int64, nextOccurrence: Date?, now: Date) throws -> ScheduledJob?
  /// ACTIVE|PAUSED→CANCELLED, next NULL, row retained.
  func cancel(id: Int64, now: Date) throws -> ScheduledJob?

  func schedulerState() throws -> SchedulerState
  /// Upserts scheduler_state.last_tick_at.
  func recordTick(at tickTime: Date) throws

  /// Spec §12 (Phase 4): creates/reuses the sched:heartbeat session, inserts the template
  /// trigger message + PENDING run (origin 'heartbeat', job_id NULL), and updates
  /// scheduler_state heartbeat fields (last_heartbeat_at, day-counter roll) — one transaction.
  func fireHeartbeat(
    prompt: String,
    ownerChatId: Int64,
    now: Date,
    day: String
  ) throws -> ClaimedFire
}
