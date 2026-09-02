/// `RunOrigin` collapses a ticker occurrence and an owner `/runnow` into `.scheduled`. The binding
/// must freeze which one actually happened, so learning carries its own two-case kind rather than
/// widening `RunOrigin`, which the scheduler, usage totals and budget gate all branch on.
public enum ScheduledFireKind: String, Sendable, Equatable, CaseIterable {
  case scheduledOccurrence = "scheduled_occurrence"
  case ownerRunNow = "owner_run_now"
}

/// The typed cause every terminal transition of a bound run records alongside its winning state.
/// `RunState` alone cannot distinguish task failure from provider, storage, budget, policy, approval
/// or owner-interruption causes.
///
/// There is no `task_degraded` case. The degraded path delivers a canned owner-facing failure
/// notice in place of an answer, so a degraded run is an infrastructure or context failure, never
/// task evidence — every `DegradationKind` maps onto one of the causes below instead.
public enum TerminalCause: String, Sendable, Equatable, CaseIterable {
  case taskCompleted = "task_completed"
  case providerFailure = "provider_failure"
  case storageFailure = "storage_failure"
  case budgetStopped = "budget_stopped"
  case policyBlocked = "policy_blocked"
  case approvalUnresolved = "approval_unresolved"
  case approvalDenied = "approval_denied"
  case ownerCancelled = "owner_cancelled"
  case superseded
  case unknown
  case incomplete
}

/// The deterministic evidence taxonomy a sealed run's terminal cause and transcript resolve to,
/// before any learning model spend. Only `eligibleTaskEvidence` ever reaches the evaluator.
public enum LearningEligibility: String, Sendable, Equatable, CaseIterable {
  case eligibleTaskEvidence = "eligible_task_evidence"
  case transientInfrastructureFailure = "transient_infrastructure_failure"
  case policyOrSecurityBlock = "policy_or_security_block"
  case ownerInterruption = "owner_interruption"
  case insufficientEvidence = "insufficient_evidence"
  case unsupportedTerminalState = "unsupported_terminal_state"
}

/// Which of the two model calls a `LearningOperationKey` claims. `scheduled-learning/v1` never
/// dispatches a third kind of learning-model call.
public enum LearningPhase: String, Sendable, Hashable, CaseIterable {
  case evaluator
  case reflector
}

/// The lifecycle of one durable `learning_operations` row, from claim through a network-boundary
/// result or a restart's reconciled outcome.
public enum LearningOperationState: String, Sendable, Equatable {
  case pending
  case claimed
  case started
  case succeeded
  case failedNoCall = "failed_no_call"
  case failed
  case interruptedUnknown = "interrupted_unknown"
}

/// Why an operation closed without ever reaching the network, or with a result the operation cannot
/// use.
public enum LearningOperationFailure: String, Sendable, Equatable {
  case budgetDenied = "budget_denied"
  case carrierPolicyDenied = "carrier_policy_denied"
  case schemaInvalid = "schema_invalid"
  case providerTerminal = "provider_terminal"
}

/// The evaluator's raw structured verdict on one run, before owner precedence resolves it into an
/// `EffectiveOutcome`.
public enum EvaluatorOutcome: String, Sendable, Equatable {
  case noIssue = "no_issue"
  case reusableIssue = "reusable_issue"
  case transientIssue = "transient_issue"
  case uncertain
}

/// The one decision input every run resolves to, after owner precedence is applied over the raw
/// evaluator outcome. Not a confidence score or an evidence-strength claim.
public enum EffectiveOutcome: Sendable, Equatable {
  case positive
  case negative(issueCodes: [String])
  case neutral
}

/// Nine signals. The validated reducer's `_SIGNAL_SUBJECT_KINDS` carries `promotion_rollback`
/// against a `promotion` subject, and the accepted rollback rule names explicit owner rollback as
/// its first trigger — without this case that rule has no way to fire.
public enum OwnerSignal: String, Sendable, Equatable, CaseIterable {
  case resultUseful = "result_useful"
  case resultNotUseful = "result_not_useful"
  case resultCorrection = "result_correction"
  case evaluationConfirm = "evaluation_confirm"
  case evaluationDispute = "evaluation_dispute"
  case candidateApprove = "candidate_approve"
  case candidateReject = "candidate_reject"
  case candidateEdit = "candidate_edit"
  case promotionRollback = "promotion_rollback"
}

/// What an `OwnerSignal` targets. A candidate binds two to five evaluations, so a signal must name
/// which exact subject it addresses rather than the candidate's whole source manifest.
public enum FeedbackSubjectKind: String, Sendable, Equatable, CaseIterable {
  case run
  case evaluation
  case candidate
  case promotion
}

/// The lifecycle of one trial run assignment, from creation through primary settlement to its
/// resolved learning outcome.
public enum TrialAssignmentState: String, Sendable, Equatable {
  case created
  case primaryRunSettled = "primary_run_settled"
  case learningOutcomeUnresolved = "learning_outcome_unresolved"
  case learningOutcomeResolved = "learning_outcome_resolved"
}

/// What the trial policy decides once an assignment's exposure and settlement state are known.
public enum TrialDecision: Sendable, Equatable {
  case wait
  case closeAssignment(reason: String)
  case promote
  case fallback(reason: String)
}
