import Foundation

public struct ScheduleArmResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let job: ScheduledJob?

  public init(newlyClaimed: Bool, job: ScheduledJob?) {
    self.newlyClaimed = newlyClaimed
    self.job = job
  }
}

public protocol ScheduleCommandStore: Sendable {
  /// Atomic confirmed arm: claim update + insert job + jobCreated audit in one write.
  /// The inserted job is the exact parked draft — the caller never re-parses (TOCTOU kill).
  func applyArm(updateId: Int64, job: NewScheduledJob, now: Date) throws
    -> ScheduleArmResult
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
  // status='ACTIVE' AND next_occurrence <= now
  func dueJobs(now: Date) throws -> [ScheduledJob]

  /// The whole fused fire transaction. `due` is the CAS predicate (the stored
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

  /// Run-now: the same fused insert set with NO schedule advance. Requires
  /// status ACTIVE or PAUSED (nil otherwise). fireAt = now; jobExecuted audited in-txn.
  func fireNow(jobId: Int64, now: Date) throws -> ClaimedFire?

  /// Misfire skip: advance next_occurrence past now with no run (nil ⇒ one-shot →
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

  /// Heartbeat fire: creates/reuses the sched:heartbeat session, inserts the template
  /// trigger message + PENDING run (origin 'heartbeat', job_id NULL), and updates
  /// scheduler_state heartbeat fields (last_heartbeat_at, day-counter roll) — one transaction.
  func fireHeartbeat(
    prompt: String,
    ownerChatId: Int64,
    now: Date,
    day: String
  ) throws -> ClaimedFire
}
