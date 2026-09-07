import ClawCore
import Foundation
import GRDB

extension ScheduledLearningStoreGRDB: LearningWorkflowStore {
  public func learningState(jobId: Int64) throws(StoreError) -> JobLearningState? {
    try database.readMapping { db in
      try Self.readState(db, jobId: jobId)
    }
  }

  public func workflowJobs(after jobId: Int64, limit: Int) throws(StoreError) -> [Int64] {
    try database.readMapping { db in
      try Int64.fetchAll(
        db,
        sql: """
          SELECT job_id FROM job_learning_state WHERE job_id > ? ORDER BY job_id LIMIT ?
          """,
        arguments: [jobId, max(0, limit)]
      )
    }
  }

  public func workflowRuns(jobId: Int64, after runId: Int64, limit: Int)
    throws(StoreError) -> [Int64]
  {
    try database.readMapping { db in
      try Int64.fetchAll(
        db,
        sql: """
          SELECT binding.run_id FROM run_learning_bindings AS binding
          JOIN run_settlements AS settlement ON settlement.run_id = binding.run_id
          JOIN job_learning_state AS state ON state.job_id = binding.job_id
          LEFT JOIN learning_evidence AS evidence ON evidence.run_id = binding.run_id
          WHERE binding.job_id = ? AND binding.run_id > ?
            AND binding.learning_epoch = state.learning_epoch AND settlement.settled_at IS NOT NULL
            AND (evidence.run_id IS NULL OR (evidence.eligibility = ? AND evidence.payload IS NOT NULL))
            AND NOT EXISTS (SELECT 1 FROM learning_evaluations AS evaluation
              WHERE evaluation.run_id = binding.run_id)
            AND NOT EXISTS (SELECT 1 FROM learning_operations AS operation
              WHERE operation.job_id = binding.job_id
                AND operation.learning_epoch = binding.learning_epoch
                AND operation.phase = ? AND operation.source_digest = evidence.evidence_digest
                AND operation.attempt_generation = (SELECT MAX(latest.attempt_generation)
                  FROM learning_operations AS latest WHERE latest.key_digest = operation.key_digest)
                AND operation.state NOT IN (?, ?))
          ORDER BY binding.run_id LIMIT ?
          """,
        arguments: [
          jobId, runId, LearningEligibility.eligibleTaskEvidence.rawValue,
          LearningPhase.evaluator.rawValue,
          LearningOperationState.pending.rawValue,
          LearningOperationState.interruptedUnknown.rawValue,
          max(0, limit),
        ]
      )
    }
  }

  public func workflowCandidates(jobId: Int64) throws(StoreError) -> [CandidateDigest] {
    try database.readMapping { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT candidate.candidate_digest FROM learning_candidates AS candidate
          JOIN job_learning_state AS state ON state.job_id = candidate.job_id
          WHERE candidate.job_id = ? AND candidate.learning_epoch = state.learning_epoch
            AND candidate.base_digest = state.stable_lesson_set_digest
            AND (candidate.frozen_feedback_revision = state.feedback_revision
              OR EXISTS (SELECT 1 FROM learning_trials AS admitted
                WHERE admitted.candidate_digest = candidate.candidate_digest))
            AND NOT EXISTS (SELECT 1 FROM feedback_targets AS target
              WHERE target.subject_kind = ? AND target.subject_digest = candidate.candidate_digest)
            AND NOT EXISTS (SELECT 1 FROM learning_trials AS trial
              WHERE trial.candidate_digest = candidate.candidate_digest AND trial.state NOT IN (?, ?))
            AND NOT EXISTS (SELECT 1 FROM learning_candidates AS successor
              WHERE successor.predecessor_digest = candidate.candidate_digest)
          ORDER BY candidate.created_at, candidate.candidate_digest
          """,
        arguments: [
          jobId, FeedbackSubjectKind.candidate.rawValue,
          LearningTrialState.open.rawValue, LearningTrialState.draining.rawValue,
        ]
      )
      .map(CandidateDigest.init(rawValue:))
    }
  }

  public func workflowControls(jobId: Int64) throws(StoreError) -> [LearningCandidateControl] {
    try database.readMapping { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT event.event_id, event.subject_digest, event.signal, event.payload
          FROM feedback_events AS event
          JOIN job_learning_state AS state ON state.job_id = event.job_id
          WHERE event.job_id = ? AND event.learning_epoch = state.learning_epoch
            AND event.subject_kind = ? AND event.signal IN (?, ?)
            AND NOT EXISTS (SELECT 1 FROM feedback_events AS newer
              WHERE newer.supersedes = event.event_id)
            AND NOT EXISTS (SELECT 1 FROM learning_candidates AS successor
              WHERE successor.predecessor_digest = event.subject_digest)
          ORDER BY event.feedback_revision, event.event_id
          """,
        arguments: [
          jobId, FeedbackSubjectKind.candidate.rawValue,
          OwnerSignal.candidateApprove.rawValue, OwnerSignal.candidateEdit.rawValue,
        ]
      )
      .compactMap { row in
        guard let signal = OwnerSignal(rawValue: row["signal"]) else {
          return nil
        }
        return LearningCandidateControl(
          eventId: row["event_id"],
          candidate: CandidateDigest(rawValue: row["subject_digest"]),
          signal: signal,
          payload: row["payload"]
        )
      }
    }
  }

  public func workflowRollbacks(jobId: Int64) throws(StoreError) -> [RollbackTrigger] {
    try database.readMapping { db in
      guard let state = try Self.readState(db, jobId: jobId),
        let promotion = try Self.currentPromotion(db, state: state)
      else {
        return []
      }
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT event_id, signal, subject_kind, subject_digest FROM feedback_events
          WHERE job_id = ? AND learning_epoch = ?
            AND feedback_revision > ?
            AND signal IN (?, ?, ?, ?, ?) ORDER BY feedback_revision, event_id
          """,
        arguments: [
          jobId, promotion.inputs.identity.epoch.value, promotion.inputs.feedbackRevision.value,
          OwnerSignal.promotionRollback.rawValue, OwnerSignal.candidateReject.rawValue,
          OwnerSignal.resultNotUseful.rawValue, OwnerSignal.resultCorrection.rawValue,
          OwnerSignal.evaluationDispute.rawValue,
        ]
      )
      let receipts = try Row.fetchAll(
        db,
        sql:
          "SELECT decision_id, inputs, result FROM learning_decisions WHERE job_id = ? AND kind = ?",
        arguments: [jobId, LearningDecisionKind.rollback.rawValue]
      )
      .map(Self.decodeTerminalReceipt)
      return rows.compactMap { row in
        let subject: String = row["subject_digest"]
        let kind = FeedbackSubjectKind(rawValue: row["subject_kind"])
        let signal = OwnerSignal(rawValue: row["signal"])
        let trigger: RollbackTrigger
        if signal == .promotionRollback || signal == .candidateReject {
          guard
            (kind == .promotion && subject == promotion.promotionSubject)
              || (kind == .candidate && subject == promotion.inputs.candidateDigest.rawValue)
          else {
            return nil
          }
          trigger = .ownerFeedback(promotionId: promotion.decisionId, eventId: row["event_id"])
        } else {
          guard
            promotion.cohort.contains(where: { support in
              support.outcome == .positive
                && ((kind == .run && subject == String(support.runId))
                  || (kind == .evaluation && subject == support.evaluationDigest?.rawValue))
            })
          else {
            return nil
          }
          trigger = .supportWithdrawal(promotionId: promotion.decisionId, eventId: row["event_id"])
        }
        return receipts.contains(where: { receipt in
          receipt.record.rollbackTrigger == trigger
        }) ? nil : trigger
      }
    }
  }
}
