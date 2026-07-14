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
  func applyArm(
    updateId: Int64,
    job: NewScheduledJob,
    now: Date
  ) throws(StoreError) -> ScheduleArmResult
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

/// Outcome of a `/runnow` attempt. A bare optional could not tell "no such job" apart from
/// "the job exists but a prior run on its session is still live" — the owner-facing ack differs.
public enum RunNowOutcome: Sendable, Equatable {
  /// The fire proceeded; the run is ready to enqueue.
  case fired(ClaimedFire)
  /// A prior run on this job's session is still live, so the fire was skipped to protect its
  /// context window. The job is healthy — the owner should be told a run is already in progress.
  case skippedActiveRun
  /// The job is absent or not in an active/paused state — nothing to run now.
  case ineligible
}

public protocol ScheduledJobStore: Sendable {
  func create(_ job: NewScheduledJob, now: Date) throws(StoreError) -> ScheduledJob
  func job(id: Int64) throws(StoreError) -> ScheduledJob?
  func listAll() throws(StoreError) -> [ScheduledJob]
  // status='ACTIVE' AND next_occurrence <= now
  func dueJobs(now: Date) throws(StoreError) -> [ScheduledJob]

  /// The whole fused fire transaction. `due` is the CAS predicate (the stored
  /// next_occurrence being claimed); `fireAt` is T_fire (== due on time, the latest missed
  /// occurrence when coalescing); `nextOccurrence` nil ⇒ one-shot → COMPLETED. Creates the
  /// job session on first fire (session_key = SessionKey.scheduledJob(id:)), inserts the
  /// trigger message (role user, provenance trusted, text = job prompt), the PENDING run
  /// (origin 'scheduled', job_id set), and the jobExecuted audit row — one writeMapping.
  /// Returns nil for either of two distinct reasons, both meaning "no run to enqueue": the CAS
  /// matched no row (claimed elsewhere / job mutated) — nothing is written; OR the job's session
  /// already has a live run (the overlap guard) — nothing is inserted except a `job_overlap_skipped`
  /// audit, and the schedule advance from the CAS still stands (the occurrence drops misfire-style).
  func claimAndFire(
    jobId: Int64,
    due: Date,
    fireAt: Date,
    nextOccurrence: Date?,
    now: Date
  ) throws(StoreError) -> ClaimedFire?

  /// Run-now: the same fused insert set with NO schedule advance. Requires status ACTIVE or
  /// PAUSED (`.ineligible` otherwise). fireAt = now; jobExecuted audited in-txn. Returns
  /// `.skippedActiveRun` when a prior run on the job's session is still live (the overlap guard).
  func fireNow(jobId: Int64, now: Date) throws(StoreError) -> RunNowOutcome

  /// Misfire skip: advance next_occurrence past now with no run (nil ⇒ one-shot →
  /// COMPLETED), update scheduler_state.last_misfire_at / last_misfire_skipped_count, and
  /// audit jobMisfire — one transaction. Returns false when the job was concurrently mutated.
  func skipMisfire(
    jobId: Int64,
    due: Date,
    nextOccurrence: Date?,
    skippedCount: Int,
    now: Date
  ) throws(StoreError) -> Bool

  /// ACTIVE→PAUSED, idempotent.
  func pause(id: Int64, now: Date) throws(StoreError) -> ScheduledJob?
  /// PAUSED→ACTIVE; the caller recomputes next_occurrence from now.
  func resume(
    id: Int64,
    nextOccurrence: Date?,
    now: Date
  ) throws(StoreError) -> ScheduledJob?
  /// ACTIVE|PAUSED→CANCELLED, next NULL, row retained.
  func cancel(id: Int64, now: Date) throws(StoreError) -> ScheduledJob?

  func schedulerState() throws(StoreError) -> SchedulerState
  /// Upserts scheduler_state.last_tick_at.
  func recordTick(at tickTime: Date) throws(StoreError)

  /// Heartbeat fire: creates/reuses the sched:heartbeat session, inserts the template
  /// trigger message + PENDING run (origin 'heartbeat', job_id NULL), and updates
  /// scheduler_state heartbeat fields (last_heartbeat_at, day-counter roll) — one transaction.
  /// Returns nil when the heartbeat session already carries a live run: a prior beat is still
  /// in flight, so firing again would reset its shared context window — the beat is skipped.
  func fireHeartbeat(
    prompt: String,
    ownerChatId: Int64,
    now: Date,
    day: String
  ) throws(StoreError) -> ClaimedFire?
}
