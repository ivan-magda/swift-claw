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
  public let trialId: Int64
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let generation: Int
  public let candidateDigest: CandidateDigest
  public let maxAssignments: Int
  public let consumedAssignments: Int
  public let assignmentDeadline: Date
  public let state: LearningTrialState

  /// The two bounds that stop new exposure. Reaching either drains the trial: runs already
  /// assigned still finish, but no further fire binds to the candidate.
  public func acceptsAssignment(at moment: Date) -> Bool {
    state == .open && consumedAssignments < maxAssignments && moment < assignmentDeadline
  }

  public init(
    trialId: Int64,
    jobId: Int64,
    epoch: LearningEpoch,
    generation: Int,
    candidateDigest: CandidateDigest,
    maxAssignments: Int,
    consumedAssignments: Int,
    assignmentDeadline: Date,
    state: LearningTrialState
  ) {
    self.trialId = trialId
    self.jobId = jobId
    self.epoch = epoch
    self.generation = generation
    self.candidateDigest = candidateDigest
    self.maxAssignments = maxAssignments
    self.consumedAssignments = consumedAssignments
    self.assignmentDeadline = assignmentDeadline
    self.state = state
  }
}
