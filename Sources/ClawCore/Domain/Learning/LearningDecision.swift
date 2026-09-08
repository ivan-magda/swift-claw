import Foundation

/// The reviewed predicates of one terminal trial request, never rebound to newer state.
public struct TrialDecisionInputs: Sendable, Equatable, Codable {
  public let identity: LearningTrialIdentity
  public let candidateDigest: CandidateDigest
  public let replacementDigest: LessonSetDigest
  public let baseDigest: LessonSetDigest
  public let baseRevision: StableRevision
  public let feedbackRevision: FeedbackRevision
  public let algorithm: LearningAlgorithm

  public init(trial: LearningTrial, feedbackRevision: FeedbackRevision) {
    identity = trial.identity
    candidateDigest = trial.candidateDigest
    replacementDigest = trial.replacementDigest
    baseDigest = trial.baseDigest
    baseRevision = trial.baseRevision
    self.feedbackRevision = feedbackRevision
    algorithm = trial.algorithm
  }
}

public enum LearningDecisionResult: String, Sendable, Equatable, Codable {
  case promoted
  case fallback
  case rolledBack = "rolled_back"
  case stale
}

/// Exact authoritative resolution retained with the complete promotion cohort.
public struct DecisionSupport: Sendable, Equatable, Codable {
  public let runId: Int64
  public let outcome: TrialOutcomeKind?
  public let evaluationDigest: EvaluationDigest?
  public let evaluationRequired: Bool
  public let feedbackRevision: FeedbackRevision?
  public let correctionEventDigest: FeedbackEventDigest?
  public let ownerConfirmed: Bool

  public init(assignment: TrialAssignment) {
    runId = assignment.identity.runId
    let evidence = assignment.resolvedEvidence
    outcome = evidence?.outcome
    evaluationDigest = evidence?.evaluationDigest
    evaluationRequired = evidence?.evaluationRequired ?? false
    feedbackRevision = evidence?.effectiveFeedbackRevision
    correctionEventDigest = evidence?.correctionEventDigest
    ownerConfirmed = evidence?.ownerConfirmed ?? false
  }
}

public enum LearningDecisionKind: String, Sendable, Equatable, Codable {
  case trial = "trial_decision"
  case rollback
}

/// Stored result bytes exclude the database identity assigned by the insert.
public struct LearningDecisionRecord: Sendable, Equatable, Codable {
  public let result: LearningDecisionResult
  public let reason: String
  public let cohort: [DecisionSupport]
  public let stableRevision: StableRevision
  public let rollbackTrigger: RollbackTrigger?

  public init(
    result: LearningDecisionResult,
    reason: String,
    cohort: [DecisionSupport],
    stableRevision: StableRevision,
    rollbackTrigger: RollbackTrigger? = nil
  ) {
    self.result = result
    self.reason = reason
    self.cohort = cohort
    self.stableRevision = stableRevision
    self.rollbackTrigger = rollbackTrigger
  }
}

public struct DecisionReceipt: Sendable, Equatable {
  public let decisionId: Int64
  public let inputs: TrialDecisionInputs
  public let record: LearningDecisionRecord
  public var result: LearningDecisionResult { record.result }
  public var cohort: [DecisionSupport] { record.cohort }
  public var promotionSubject: String { String(decisionId) }

  public init(decisionId: Int64, inputs: TrialDecisionInputs, record: LearningDecisionRecord) {
    self.decisionId = decisionId
    self.inputs = inputs
    self.record = record
  }
}

public enum LearningSafetyFailure: String, Sendable, Equatable, Codable, CaseIterable {
  case security
  case secretLeakage = "secret_leakage"
  case corruption
  case invariantViolation = "invariant_violation"
}

public enum AdapterRollbackOutcome: String, Sendable, Equatable, Codable {
  case critical
  case regression
}

/// Owner triggers name durable authenticated events. Safety receipts come from trusted code;
/// the adapter branch remains inert while production freezes no adapter.
public enum RollbackTrigger: Sendable, Equatable, Codable {
  case ownerFeedback(promotionId: Int64, eventId: Int64)
  case supportWithdrawal(promotionId: Int64, eventId: Int64)
  case adapter(promotionId: Int64, adapterId: String, outcome: AdapterRollbackOutcome)
  case safety(promotionId: Int64, receiptDigest: String, failure: LearningSafetyFailure)

  public var promotionId: Int64 {
    switch self {
    case .ownerFeedback(let id, _), .supportWithdrawal(let id, _),
      .adapter(let id, _, _), .safety(let id, _, _):
      id
    }
  }
}

public enum PromotionReplyOutcome: Sendable, Equatable {
  case committed
  case duplicate
  case stale
}
