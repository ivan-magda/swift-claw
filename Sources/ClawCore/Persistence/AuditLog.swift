import Foundation

/// Who an audit event is attributed to. A small closed set so the audit trail can't record a
/// typo'd actor; persisted via `rawValue` at the store seam.
public enum AuditActor: String, Sendable, Equatable {
  case owner
  case groupMember = "group_member"
  case assistant
  case system
}

/// The category of an audit event (the specific tool/reason rides in `tool`/`decision`, not here).
/// Closed by design: a controlled vocabulary makes the audit log queryable and typo-proof. Add a
/// case when a new kind of event needs recording.
public enum AuditAction: String, Sendable, Equatable {
  case messageIn = "message_in"
  case toolCall = "tool_call"
  case memoryWrite = "memory_write"
  case memoryDelete = "memory_delete"
  case turnCompleted = "turn_completed"
  case turnDegraded = "turn_degraded"
  case turnBudgetStopped = "turn_budget_stopped"
  case budgetTripped = "budget_tripped"
  case turnCancelled = "turn_cancelled"
  case providerFallback = "provider_fallback"
  case turnSuperseded = "turn_superseded"
  case jobCreated = "job_created"
  case jobExecuted = "job_executed"
  case jobPaused = "job_paused"
  case jobResumed = "job_resumed"
  case jobCancelled = "job_cancelled"
  case jobFailed = "job_failed"
  case jobMisfire = "job_misfire"
  case jobOverlapSkipped = "job_overlap_skipped"
  case heartbeatFired = "heartbeat_fired"
  case heartbeatSuppressed = "heartbeat_suppressed"
  case heartbeatSkipped = "heartbeat_skipped"
  case approvalRequested = "approval_requested"
  case approvalGranted = "approval_granted"
  case approvalDenied = "approval_denied"
  case learningBound = "learning_bound"
  case learningFeedback = "learning_feedback"
  case learningEvaluated = "learning_evaluated"
  case learningCandidateAdmitted = "learning_candidate_admitted"
  case learningReset = "learning_reset"
}

public struct AuditEvent: Sendable, Equatable {
  public let actor: AuditActor
  public let action: AuditAction
  public let tool: String?
  public let argsRedacted: String
  public let resultSize: Int
  public let decision: String
  public let runId: Int64?
  public let sessionId: Int64?
  public let ts: Date

  public init(
    actor: AuditActor,
    action: AuditAction,
    tool: String? = nil,
    argsRedacted: String = "",
    resultSize: Int = 0,
    decision: String = "ok",
    runId: Int64? = nil,
    sessionId: Int64? = nil,
    ts: Date
  ) {
    self.actor = actor
    self.action = action
    self.tool = tool
    self.argsRedacted = argsRedacted
    self.resultSize = resultSize
    self.decision = decision
    self.runId = runId
    self.sessionId = sessionId
    self.ts = ts
  }
}

public protocol AuditLog: Sendable {
  func appendAudit(_ event: AuditEvent) throws(StoreError)
}
