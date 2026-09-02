import Foundation

/// One job's learning position: which epoch it is in, which lesson set is currently stable, and
/// which revisions the frozen work under it was computed against.
public struct JobLearningState: Sendable, Equatable {
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let stableDigest: LessonSetDigest
  public let stableRevision: StableRevision
  /// A denormalized convenience pointer, maintained by the trial lifecycle. `learning_trials` is
  /// authoritative — it holds the state machine and the partial unique index — so this value is
  /// never read for a correctness decision; `openTrial(jobId:)` is that read.
  public let openTrialId: Int64?
  public let feedbackRevision: FeedbackRevision

  public init(
    jobId: Int64,
    epoch: LearningEpoch,
    stableDigest: LessonSetDigest,
    stableRevision: StableRevision,
    openTrialId: Int64?,
    feedbackRevision: FeedbackRevision
  ) {
    self.jobId = jobId
    self.epoch = epoch
    self.stableDigest = stableDigest
    self.stableRevision = stableRevision
    self.openTrialId = openTrialId
    self.feedbackRevision = feedbackRevision
  }
}

public protocol ScheduledLearningStore: Sendable {
  /// Idempotent. Inserts this job's learning state and its canonical empty lesson set together,
  /// or returns the state already there. The fire transaction calls it, so a job never fires with
  /// a binding that points at a lesson set that does not exist.
  func armJob(jobId: Int64, now: Date) throws(StoreError) -> JobLearningState

  /// Exact identity. Returns nil when the digest belongs to another job.
  func lessonSet(jobId: Int64, digest: LessonSetDigest) throws(StoreError) -> LessonSet?

  /// What the run's fire froze about its learning context. Nil for a run created without a
  /// binding — a heartbeat, a fire under a disarmed daemon, or a run that predates bindings.
  func binding(runId: Int64) throws(StoreError) -> RunLearningBinding?

  /// The job's live trial, open or draining, read from the authoritative `learning_trials` state.
  /// Nil once the trial is decided, which is also what makes a job admissible for a new candidate.
  /// Every decision about whether a trial is still live goes through here, never through
  /// `JobLearningState.openTrialId`.
  func openTrial(jobId: Int64) throws(StoreError) -> LearningTrial?

  /// The terminal receipt the transaction that won the run's state wrote. Nil for a run that never
  /// bound, or one that is still live.
  func settlement(runId: Int64) throws(StoreError) -> RunSettlement?

  /// The lane tail's deferred settlement: freezes a bound run's evidence once every primary fact
  /// has unwound. Idempotent and inert for an unbound, still-live or already-settled run, so the
  /// tail can call it unconditionally.
  ///
  /// - Returns: whether this call is the one that froze the evidence.
  @discardableResult
  func settleFromLane(runId: Int64, now: Date) throws(StoreError) -> Bool

  /// Freezes the surface a bound run is executing against, called at pickup while every value in
  /// it is still current. Insert-once and inert for an unbound run: a second call keeps the first
  /// snapshot, because a value captured later describes a surface the run never ran on.
  func freezeCompatibility(runId: Int64, surface: RunSurface) throws(StoreError)

  /// The frozen surface. Nil for a run that never froze one, which makes it unusable as evidence
  /// rather than a run to guess about.
  func compatibility(runId: Int64) throws(StoreError) -> RunCompatibility?

  /// Bound runs whose evidence is frozen and whose receipt is not yet sealed, oldest settlement
  /// first. Selects on `settled_at`, never on terminality: a terminal run with a primary fact still
  /// owed has facts that can still change.
  func unsealed(limit: Int) throws(StoreError) -> [Int64]

  /// The one idempotent sealing transaction, keyed by `run_id`. It verifies the run is bound and
  /// settled, compares the binding epoch against current job state, resolves the frozen surface and
  /// the lesson set the run ran against, classifies the run, and writes the eligibility receipt
  /// with its payload — or a content-free tombstone — in one statement group. A row already present
  /// writes nothing.
  @discardableResult
  func sealEvidence(runId: Int64, now: Date) throws(StoreError) -> SealOutcome

  /// The sealed receipt, payload included while retention still holds it.
  func evidence(runId: Int64) throws(StoreError) -> SealedEvidence?
}
