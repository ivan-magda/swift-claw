import Foundation

/// The state identity captured immediately before an owner reset raises the learning epoch.
public struct LearningResetDecisionInputs: Sendable, Equatable, Codable {
  public let oldEpoch: LearningEpoch
  public let oldStableDigest: LessonSetDigest
  public let oldStableRevision: StableRevision
  public let feedbackRevisionAtCut: FeedbackRevision
  public let priorOpenTrialID: Int64?

  public init(
    oldEpoch: LearningEpoch,
    oldStableDigest: LessonSetDigest,
    oldStableRevision: StableRevision,
    feedbackRevisionAtCut: FeedbackRevision,
    priorOpenTrialID: Int64?
  ) {
    self.oldEpoch = oldEpoch
    self.oldStableDigest = oldStableDigest
    self.oldStableRevision = oldStableRevision
    self.feedbackRevisionAtCut = feedbackRevisionAtCut
    self.priorOpenTrialID = priorOpenTrialID
  }

  enum CodingKeys: String, CodingKey {
    case oldEpoch = "old_epoch"
    case oldStableDigest = "old_stable_digest"
    case oldStableRevision = "old_stable_revision"
    case feedbackRevisionAtCut = "feedback_revision_at_cut"
    case priorOpenTrialID = "prior_open_trial_id"
  }
}

/// The immutable identity of one live trial closed by a reset barrier.
public struct ResetTrialIdentity: Sendable, Equatable, Codable {
  public let trialID: Int64
  public let jobID: Int64
  public let epoch: LearningEpoch
  public let generation: Int
  public let baseDigest: LessonSetDigest
  public let candidateDigest: CandidateDigest
  public let algorithm: LearningAlgorithm

  public init(
    trialID: Int64,
    jobID: Int64,
    epoch: LearningEpoch,
    generation: Int,
    baseDigest: LessonSetDigest,
    candidateDigest: CandidateDigest,
    algorithm: LearningAlgorithm
  ) {
    self.trialID = trialID
    self.jobID = jobID
    self.epoch = epoch
    self.generation = generation
    self.baseDigest = baseDigest
    self.candidateDigest = candidateDigest
    self.algorithm = algorithm
  }

  enum CodingKeys: String, CodingKey {
    case trialID = "trial_id"
    case jobID = "job_id"
    case epoch = "learning_epoch"
    case generation
    case baseDigest = "base_digest"
    case candidateDigest = "candidate_digest"
    case algorithm
  }
}

/// The complete identity-only result of one effective reset barrier.
public struct LearningResetDecisionResult: Sendable, Equatable, Codable {
  public let newEpoch: LearningEpoch
  public let emptyStableDigest: LessonSetDigest
  public let newStableRevision: StableRevision
  public let closedTrials: [ResetTrialIdentity]
  public let invalidatedTargetCount: Int
  public let invalidatedChallengeCount: Int
  public let staleNoCallOperationIDs: [LearningOperationID]
  public let inFlightOperationIDs: [LearningOperationID]

  public init(  // swiftlint:disable:this function_parameter_count
    newEpoch: LearningEpoch,
    emptyStableDigest: LessonSetDigest,
    newStableRevision: StableRevision,
    closedTrials: [ResetTrialIdentity],
    invalidatedTargetCount: Int,
    invalidatedChallengeCount: Int,
    staleNoCallOperationIDs: [LearningOperationID],
    inFlightOperationIDs: [LearningOperationID]
  ) {
    self.newEpoch = newEpoch
    self.emptyStableDigest = emptyStableDigest
    self.newStableRevision = newStableRevision
    self.closedTrials = closedTrials
    self.invalidatedTargetCount = invalidatedTargetCount
    self.invalidatedChallengeCount = invalidatedChallengeCount
    self.staleNoCallOperationIDs = staleNoCallOperationIDs
    self.inFlightOperationIDs = inFlightOperationIDs
  }

  enum CodingKeys: String, CodingKey {
    case newEpoch = "new_epoch"
    case emptyStableDigest = "empty_stable_digest"
    case newStableRevision = "new_stable_revision"
    case closedTrials = "closed_trials"
    case invalidatedTargetCount = "invalidated_target_count"
    case invalidatedChallengeCount = "invalidated_challenge_count"
    case staleNoCallOperationIDs = "stale_no_call_operation_ids"
    case inFlightOperationIDs = "in_flight_operation_ids"
  }
}

/// The reset decision row plus its canonical typed input and result payloads.
public struct ResetReceipt: Sendable, Equatable {
  public static let kind = "learning_reset"

  public let decisionID: Int64
  public let jobID: Int64
  public let algorithm: LearningAlgorithm
  public let decidedAt: Date
  public let inputs: LearningResetDecisionInputs
  public let result: LearningResetDecisionResult

  public init(
    decisionID: Int64,
    jobID: Int64,
    algorithm: LearningAlgorithm,
    decidedAt: Date,
    inputs: LearningResetDecisionInputs,
    result: LearningResetDecisionResult
  ) {
    self.decisionID = decisionID
    self.jobID = jobID
    self.algorithm = algorithm
    self.decidedAt = decidedAt
    self.inputs = inputs
    self.result = result
  }
}

/// The semantic result of a newly claimed owner confirmation.
public enum LearningResetOutcome: Sendable, Equatable {
  case applied(ResetReceipt)
  case alreadyReset(ResetReceipt)
  case unarmed
  case notFound
}

/// A fused transport-claim/reset result. Duplicates carry no semantic outcome by construction.
public struct ConfirmedLearningResetResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let outcome: LearningResetOutcome?

  public static let duplicate = ConfirmedLearningResetResult(newlyClaimed: false, outcome: nil)

  public static func claimed(_ outcome: LearningResetOutcome) -> ConfirmedLearningResetResult {
    ConfirmedLearningResetResult(newlyClaimed: true, outcome: outcome)
  }

  private init(newlyClaimed: Bool, outcome: LearningResetOutcome?) {
    self.newlyClaimed = newlyClaimed
    self.outcome = outcome
  }
}

/// The narrow seam used by confirmation resolution to claim and apply a reset atomically.
public protocol LearningResetApplying: Sendable {
  func applyReset(updateID: Int64, jobID: Int64, now: Date) throws(StoreError)
    -> ConfirmedLearningResetResult
}
