import Foundation

/// What one created run froze about its own learning context: which occurrence and which kind of
/// fire produced it, which job definition it ran against, and the exact lesson set it was given.
/// Written inside the fire transaction, so a run and the lessons it ran against can never exist
/// apart. A run with no binding carries no lessons and produces a technical learning exclusion.
public struct RunLearningBinding: Sendable, Equatable {
  public let runId: Int64
  public let jobId: Int64
  public let occurrenceAt: Date
  public let fireKind: ScheduledFireKind
  public let jobDefinitionDigest: JobDefinitionDigest
  public let epoch: LearningEpoch
  public let stableDigest: LessonSetDigest
  /// The set the run actually ran against: the open trial's candidate while that trial still
  /// accepts assignments, the stable set otherwise.
  public let effectiveDigest: LessonSetDigest
  public let trialId: Int64?
  public let trialGeneration: Int?

  public init(
    runId: Int64,
    jobId: Int64,
    occurrenceAt: Date,
    fireKind: ScheduledFireKind,
    jobDefinitionDigest: JobDefinitionDigest,
    epoch: LearningEpoch,
    stableDigest: LessonSetDigest,
    effectiveDigest: LessonSetDigest,
    trialId: Int64?,
    trialGeneration: Int?
  ) {
    self.runId = runId
    self.jobId = jobId
    self.occurrenceAt = occurrenceAt
    self.fireKind = fireKind
    self.jobDefinitionDigest = jobDefinitionDigest
    self.epoch = epoch
    self.stableDigest = stableDigest
    self.effectiveDigest = effectiveDigest
    self.trialId = trialId
    self.trialGeneration = trialGeneration
  }
}
