import Foundation

public enum TrialAdmissionPolicy {
  public static let assignmentWindow = EvidenceWindow.maximumAge
  public static let decisionWindow: TimeInterval = 37 * 24 * 60 * 60
  public static let maximumAssignments = 3
}

/// One live exposure of a candidate lesson set: how many of its bounded assignments are already
/// out, and until when it may grant more. A trial stops granting assignments well before it is
/// decided, so `state` and `consumedAssignments` answer different questions.
public struct LearningTrial: Sendable, Equatable {
  public let identity: LearningTrialIdentity
  public let baseDigest: LessonSetDigest
  public let baseRevision: StableRevision
  public let candidateDigest: CandidateDigest
  public let replacementDigest: LessonSetDigest
  public let algorithm: LearningAlgorithm
  public let admittedAt: Date
  public let cohortCutoff: Date
  public let maxAssignments: Int
  public let consumedAssignments: Int
  public let assignmentDeadline: Date
  public let decisionDeadline: Date
  public let state: LearningTrialState
  public let hardVetoes: Set<HardVeto>

  public var trialId: Int64 { identity.trialId }
  public var jobId: Int64 { identity.jobId }
  public var epoch: LearningEpoch { identity.epoch }
  public var generation: Int { identity.generation }

  /// The two bounds that stop new exposure. Reaching either drains the trial: runs already
  /// assigned still finish, but no further fire binds to the candidate.
  public func acceptsAssignment(occurrenceAt: Date, now: Date) -> Bool {
    state == .open
      && consumedAssignments < maxAssignments
      && occurrenceAt >= cohortCutoff
      && now < assignmentDeadline
  }

  public init(  // swiftlint:disable:this function_parameter_count
    identity: LearningTrialIdentity,
    baseDigest: LessonSetDigest,
    baseRevision: StableRevision,
    candidateDigest: CandidateDigest,
    replacementDigest: LessonSetDigest,
    algorithm: LearningAlgorithm,
    admittedAt: Date,
    cohortCutoff: Date,
    maxAssignments: Int,
    consumedAssignments: Int,
    assignmentDeadline: Date,
    decisionDeadline: Date,
    state: LearningTrialState,
    hardVetoes: Set<HardVeto>
  ) {
    self.identity = identity
    self.baseDigest = baseDigest
    self.baseRevision = baseRevision
    self.candidateDigest = candidateDigest
    self.replacementDigest = replacementDigest
    self.algorithm = algorithm
    self.admittedAt = admittedAt
    self.cohortCutoff = cohortCutoff
    self.maxAssignments = maxAssignments
    self.consumedAssignments = consumedAssignments
    self.assignmentDeadline = assignmentDeadline
    self.decisionDeadline = decisionDeadline
    self.state = state
    self.hardVetoes = hardVetoes
  }
}
