import Foundation

/// One job's learning position: which epoch it is in, which lesson set is currently stable, and
/// which revisions the frozen work under it was computed against.
public struct JobLearningState: Sendable, Equatable {
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let stableDigest: LessonSetDigest
  public let stableRevision: StableRevision
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
}
