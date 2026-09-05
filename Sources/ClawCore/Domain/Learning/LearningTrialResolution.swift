import Foundation

public struct LearningTrialIdentity: Sendable, Equatable, Hashable, Codable {
  public let trialId: Int64
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let generation: Int

  public init(trialId: Int64, jobId: Int64, epoch: LearningEpoch, generation: Int) {
    self.trialId = trialId
    self.jobId = jobId
    self.epoch = epoch
    self.generation = generation
  }
}

public struct TrialAssignmentIdentity: Sendable, Equatable, Hashable {
  public let trial: LearningTrialIdentity
  public let runId: Int64

  public init(trial: LearningTrialIdentity, runId: Int64) {
    self.trial = trial
    self.runId = runId
  }
}

public enum TrialOutcomeKind: String, Sendable, Equatable, CaseIterable, Codable {
  case positive
  case negative
  case neutral
}

public enum TrialAssignmentCloseReason: String, Sendable, Equatable, CaseIterable {
  case assignmentLimit = "assignment_limit"
  case assignmentDeadline = "assignment_deadline"
  case positiveCohortComplete = "positive_cohort_complete"
}

public enum TrialFallbackReason: String, Sendable, Equatable, CaseIterable {
  case hardVeto = "hard_veto"
  case negativeOutcome = "negative_outcome"
  case decisionDeadlineIncomplete = "decision_deadline_incomplete"
  case insufficientSupport = "insufficient_support"
}

public enum TrialDecision: Sendable, Equatable {
  case wait
  case closeAssignment(reason: TrialAssignmentCloseReason)
  case promote
  case fallback(reason: TrialFallbackReason)
}

public struct ResolvedRunEvidence: Sendable, Equatable {
  public let effective: ResolvedOutcome
  public let evaluationDigest: EvaluationDigest?
  public let correctionEventDigest: FeedbackEventDigest?
  public let effectiveFeedbackRevision: FeedbackRevision

  public init(
    effective: ResolvedOutcome,
    evaluationDigest: EvaluationDigest?,
    correctionEventDigest: FeedbackEventDigest?,
    effectiveFeedbackRevision: FeedbackRevision
  ) {
    self.effective = effective
    self.evaluationDigest = evaluationDigest
    self.correctionEventDigest = correctionEventDigest
    self.effectiveFeedbackRevision = effectiveFeedbackRevision
  }

  public var outcome: TrialOutcomeKind {
    switch effective.outcome {
    case .positive:
      return .positive
    case .negative:
      return .negative
    case .neutral:
      return .neutral
    }
  }

  public var issueCodes: [String] {
    guard case .negative(let issueCodes) = effective.outcome else {
      return []
    }
    return issueCodes
  }

  public var evaluationRequired: Bool { effective.evaluationRequired }
  public var ownerConfirmed: Bool { effective.ownerConfirmed }
  public var hardVetoes: Set<HardVeto> { effective.hardVetoes }
}

public struct TrialAssignment: Sendable, Equatable {
  public let identity: TrialAssignmentIdentity
  public let assignedAt: Date
  public let state: TrialAssignmentState
  public let resolvedEvidence: ResolvedRunEvidence?
  public let resolvedAt: Date?

  public init(
    identity: TrialAssignmentIdentity,
    assignedAt: Date,
    state: TrialAssignmentState,
    resolvedEvidence: ResolvedRunEvidence?,
    resolvedAt: Date?
  ) {
    self.identity = identity
    self.assignedAt = assignedAt
    self.state = state
    self.resolvedEvidence = resolvedEvidence
    self.resolvedAt = resolvedAt
  }
}

public enum AssignmentRecomputation: Sendable, Equatable {
  case notAssigned
  case stale
  case unchanged(TrialAssignment)
  case updated(TrialAssignment)
}

public struct TrialReconciliation: Sendable, Equatable {
  public let identity: LearningTrialIdentity
  public let didDrain: Bool
  public let assignments: [TrialAssignment]
  public let decision: TrialDecision

  public init(
    identity: LearningTrialIdentity,
    didDrain: Bool,
    assignments: [TrialAssignment],
    decision: TrialDecision
  ) {
    self.identity = identity
    self.didDrain = didDrain
    self.assignments = assignments
    self.decision = decision
  }
}

public enum TrialReconciliationResult: Sendable, Equatable {
  case stale
  case reconciled(TrialReconciliation)
}

public enum TrialPolicy {
  public static func decide(
    trial: LearningTrial,
    assignments: [TrialAssignment],
    now: Date
  ) -> TrialDecision {
    let resolved = assignments.compactMap(\.resolvedEvidence)
    let hasHardVeto =
      trial.hardVetoes.isEmpty == false
      || resolved.contains { evidence in
        evidence.hardVetoes.isEmpty == false
      }
    if hasHardVeto {
      return .fallback(reason: .hardVeto)
    }
    if resolved.contains(where: { evidence in evidence.outcome == .negative }) {
      return .fallback(reason: .negativeOutcome)
    }

    let hasUnresolved = resolved.count != assignments.count
    if now >= trial.decisionDeadline, hasUnresolved {
      return .fallback(reason: .decisionDeadlineIncomplete)
    }

    let positiveCount = resolved.count { evidence in evidence.outcome == .positive }
    let limitReached = trial.consumedAssignments >= trial.maxAssignments
    let deadlineReached = now >= trial.assignmentDeadline
    let positiveCohortComplete = positiveCount >= 2 && hasUnresolved == false
    let exposureClosed =
      trial.state == .draining
      || limitReached
      || deadlineReached
      || positiveCohortComplete
    guard exposureClosed else {
      return .wait
    }
    if trial.state == .draining, hasUnresolved {
      return .wait
    }
    if trial.state == .open, hasUnresolved {
      if limitReached {
        return .closeAssignment(reason: .assignmentLimit)
      }
      if deadlineReached {
        return .closeAssignment(reason: .assignmentDeadline)
      }
    }
    if positiveCount >= 2 {
      return .promote
    }
    return .fallback(reason: .insufficientSupport)
  }
}
