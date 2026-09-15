import Foundation

/// What one created run froze about its own learning context: which occurrence and which kind of
/// fire produced it, which job definition it ran against, and the exact lesson set it was given.
/// Written inside the fire transaction, so a run and the lessons it ran against can never exist
/// apart. A run with no binding carries no lessons and produces a technical learning exclusion.
public struct RunLearningBinding: Sendable, Equatable {
  public let runID: Int64
  public let jobID: Int64
  public let occurrenceAt: Date
  public let fireKind: ScheduledFireKind
  public let jobDefinitionDigest: JobDefinitionDigest
  public let epoch: LearningEpoch
  public let stableDigest: LessonSetDigest
  /// The set the run actually ran against: the open trial's candidate while that trial still
  /// accepts assignments, the stable set otherwise.
  public let effectiveDigest: LessonSetDigest
  public let trialID: Int64?
  public let trialGeneration: Int?

  public init(
    runID: Int64,
    jobID: Int64,
    occurrenceAt: Date,
    fireKind: ScheduledFireKind,
    jobDefinitionDigest: JobDefinitionDigest,
    epoch: LearningEpoch,
    stableDigest: LessonSetDigest,
    effectiveDigest: LessonSetDigest,
    trialID: Int64?,
    trialGeneration: Int?
  ) {
    self.runID = runID
    self.jobID = jobID
    self.occurrenceAt = occurrenceAt
    self.fireKind = fireKind
    self.jobDefinitionDigest = jobDefinitionDigest
    self.epoch = epoch
    self.stableDigest = stableDigest
    self.effectiveDigest = effectiveDigest
    self.trialID = trialID
    self.trialGeneration = trialGeneration
  }
}
