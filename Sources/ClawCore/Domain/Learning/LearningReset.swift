import Foundation

/// The state identity captured immediately before an owner reset raises the learning epoch.
public struct LearningResetDecisionInputs: Sendable, Equatable, Codable {
  public let oldEpoch: LearningEpoch
  public let oldStableDigest: LessonSetDigest
  public let oldStableRevision: StableRevision
  public let feedbackRevisionAtCut: FeedbackRevision
  public let priorOpenTrialId: Int64?

  public init(
    oldEpoch: LearningEpoch,
    oldStableDigest: LessonSetDigest,
    oldStableRevision: StableRevision,
    feedbackRevisionAtCut: FeedbackRevision,
    priorOpenTrialId: Int64?
  ) {
    self.oldEpoch = oldEpoch
    self.oldStableDigest = oldStableDigest
    self.oldStableRevision = oldStableRevision
    self.feedbackRevisionAtCut = feedbackRevisionAtCut
    self.priorOpenTrialId = priorOpenTrialId
  }

  enum CodingKeys: String, CodingKey {
    case oldEpoch = "old_epoch"
    case oldStableDigest = "old_stable_digest"
    case oldStableRevision = "old_stable_revision"
    case feedbackRevisionAtCut = "feedback_revision_at_cut"
    case priorOpenTrialId = "prior_open_trial_id"
  }
}

/// The immutable identity of one live trial closed by a reset barrier.
public struct ResetTrialIdentity: Sendable, Equatable, Codable {
  public let trialId: Int64
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let generation: Int
  public let baseDigest: LessonSetDigest
  public let candidateDigest: CandidateDigest
  public let algorithm: LearningAlgorithm

  public init(
    trialId: Int64,
    jobId: Int64,
    epoch: LearningEpoch,
    generation: Int,
    baseDigest: LessonSetDigest,
    candidateDigest: CandidateDigest,
    algorithm: LearningAlgorithm
  ) {
    self.trialId = trialId
    self.jobId = jobId
    self.epoch = epoch
    self.generation = generation
    self.baseDigest = baseDigest
    self.candidateDigest = candidateDigest
    self.algorithm = algorithm
  }

  enum CodingKeys: String, CodingKey {
    case trialId = "trial_id"
    case jobId = "job_id"
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
  public let staleNoCallOperationIds: [LearningOperationID]
  public let inFlightOperationIds: [LearningOperationID]

  public init(  // swiftlint:disable:this function_parameter_count
    newEpoch: LearningEpoch,
    emptyStableDigest: LessonSetDigest,
    newStableRevision: StableRevision,
    closedTrials: [ResetTrialIdentity],
    invalidatedTargetCount: Int,
    invalidatedChallengeCount: Int,
    staleNoCallOperationIds: [LearningOperationID],
    inFlightOperationIds: [LearningOperationID]
  ) {
    self.newEpoch = newEpoch
    self.emptyStableDigest = emptyStableDigest
    self.newStableRevision = newStableRevision
    self.closedTrials = closedTrials
    self.invalidatedTargetCount = invalidatedTargetCount
    self.invalidatedChallengeCount = invalidatedChallengeCount
    self.staleNoCallOperationIds = staleNoCallOperationIds
    self.inFlightOperationIds = inFlightOperationIds
  }

  enum CodingKeys: String, CodingKey {
    case newEpoch = "new_epoch"
    case emptyStableDigest = "empty_stable_digest"
    case newStableRevision = "new_stable_revision"
    case closedTrials = "closed_trials"
    case invalidatedTargetCount = "invalidated_target_count"
    case invalidatedChallengeCount = "invalidated_challenge_count"
    case staleNoCallOperationIds = "stale_no_call_operation_ids"
    case inFlightOperationIds = "in_flight_operation_ids"
  }
}

/// The reset decision row plus its canonical typed input and result payloads.
public struct ResetReceipt: Sendable, Equatable {
  public static let kind = "learning_reset"

  public let decisionId: Int64
  public let jobId: Int64
  public let algorithm: LearningAlgorithm
  public let decidedAt: Date
  public let inputs: LearningResetDecisionInputs
  public let result: LearningResetDecisionResult

  public init(
    decisionId: Int64,
    jobId: Int64,
    algorithm: LearningAlgorithm,
    decidedAt: Date,
    inputs: LearningResetDecisionInputs,
    result: LearningResetDecisionResult
  ) {
    self.decisionId = decisionId
    self.jobId = jobId
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
  func applyReset(
    updateId: Int64,
    jobId: Int64,
    now: Date
  ) throws(StoreError) -> ConfirmedLearningResetResult
}
