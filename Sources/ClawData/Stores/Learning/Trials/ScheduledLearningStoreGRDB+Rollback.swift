import ClawCore
import Foundation
import GRDB

// MARK: - Exact Promotion Rollback

extension ScheduledLearningStoreGRDB {
  public func currentPromotion(jobID: Int64) throws(StoreError) -> DecisionReceipt? {
    try database.readMapping { db in
      guard let state = try Self.readState(db, jobID: jobID) else {
        return nil
      }
      return try Self.currentPromotion(db, state: state)
    }
  }

  static func currentPromotion(_ db: Database, state: JobLearningState) throws -> DecisionReceipt? {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT decision_id, inputs, result FROM learning_decisions
        WHERE job_id = ? AND learning_epoch = ? AND kind = ? ORDER BY decision_id DESC
        """,
      arguments: [state.jobID, state.epoch.value, LearningDecisionKind.trial.rawValue]
    )
    for row in rows {
      let receipt = try decodeTerminalReceipt(row)
      if receipt.result == .promoted,
         receipt.inputs.replacementDigest == state.stableDigest,
         receipt.record.stableRevision == state.stableRevision
      {
        return receipt
      }
    }
    return nil
  }

  public func rollback(
    _ trigger: RollbackTrigger,
    now: Date
  ) throws(StoreError) -> DecisionReceipt? {
    try database.writeMapping { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
            SELECT decision_id, inputs, result FROM learning_decisions \
            WHERE decision_id = ? AND kind = ?
            """,
        arguments: [trigger.promotionID, LearningDecisionKind.trial.rawValue]
      )
      else {
        return nil
      }
      let promotion = try Self.decodeTerminalReceipt(row)
      guard promotion.result == .promoted else {
        return nil
      }
      let inputs = promotion.inputs
      let priorRows = try Row.fetchAll(
        db,
        sql: """
          SELECT decision_id, inputs, result FROM learning_decisions \
          WHERE job_id = ? AND kind = ?
          """,
        arguments: [inputs.identity.jobID, LearningDecisionKind.rollback.rawValue]
      )
      for priorRow in priorRows {
        let prior = try Self.decodeTerminalReceipt(priorRow)
        if prior.record.rollbackTrigger == trigger {
          return prior
        }
      }
      let state = try Self.readState(db, jobID: inputs.identity.jobID)
      let current =
        state.map { value in
          value.epoch == inputs.identity.epoch && value.stableDigest == inputs.replacementDigest
            && value.stableRevision == promotion.record.stableRevision
        } ?? false
      let valid =
        try current && Self.rollbackTriggerIsValid(db, trigger: trigger, promotion: promotion)
      let revision =
        valid
        ? StableRevision(promotion.record.stableRevision.value + 1)
        : state?.stableRevision ?? promotion.record.stableRevision
      let result: LearningDecisionResult = valid ? .rolledBack : .stale
      if valid, let state {
        try Self.closeDependentTrialForRollback(db, state: state, now: now)
      }
      let record = LearningDecisionRecord(
        result: result,
        reason: result.rawValue,
        cohort: promotion.cohort,
        stableRevision: revision,
        rollbackTrigger: trigger
      )
      let receipt = try Self.persistTerminalDecision(db, inputs: inputs, record: record, now: now)
      if valid {
        try db.execute(
          sql: """
            UPDATE job_learning_state SET stable_lesson_set_digest = ?, stable_revision = ?
            WHERE job_id = ? AND learning_epoch = ? AND stable_lesson_set_digest = ?
              AND stable_revision = ?
            """,
          arguments: [
            inputs.baseDigest.rawValue,
            revision.value,
            inputs.identity.jobID,
            inputs.identity.epoch.value,
            inputs.replacementDigest.rawValue,
            promotion.record.stableRevision.value,
          ]
        )
        guard db.changesCount == 1 else {
          throw StoreError.unexpected("rollback CAS changed inside its write transaction")
        }
      }
      return receipt
    }
  }
}

// MARK: - Trigger Authority

private extension ScheduledLearningStoreGRDB {
  static func closeDependentTrialForRollback(
    _ db: Database,
    state: JobLearningState,
    now: Date
  ) throws {
    guard let trial = try liveTrial(db, jobID: state.jobID) else {
      return
    }
    let assignments = try assignmentRunIDs(db, trialID: trial.trialID).map { runID in
      try authoritativeAssignment(db, runID: runID, trial: trial, currentState: state)
    }
    _ = try finishTrial(
      db,
      trial: trial,
      inputs: TrialDecisionInputs(trial: trial, feedbackRevision: state.feedbackRevision),
      result: .stale,
      reason: LearningDecisionResult.rolledBack.rawValue,
      cohort: assignments.map(DecisionSupport.init),
      revision: state.stableRevision,
      closesTrial: true,
      now: now
    )
  }

  static func rollbackTriggerIsValid(
    _ db: Database,
    trigger: RollbackTrigger,
    promotion: DecisionReceipt
  ) throws -> Bool {
    switch trigger {
    case .adapter:
      return false
    case .safety(_, let digest, _):
      return isCanonicalDigest(digest)
    case .ownerFeedback(_, let eventID):
      guard let event = try effectiveOwnerEvent(db, id: eventID, promotion: promotion) else {
        return false
      }
      let signal: String = event["signal"]
      let kind: String = event["subject_kind"]
      let digest: String = event["subject_digest"]
      return
        (signal == OwnerSignal.promotionRollback.rawValue
        && kind == FeedbackSubjectKind.promotion.rawValue && digest == promotion.promotionSubject)
        || (signal == OwnerSignal.candidateReject.rawValue
          && kind == FeedbackSubjectKind.candidate.rawValue
          && digest == promotion.inputs.candidateDigest.rawValue)
    case .supportWithdrawal(_, let eventID):
      guard let event = try effectiveOwnerEvent(db, id: eventID, promotion: promotion),
            let signal = OwnerSignal(rawValue: event["signal"]),
            [.resultNotUseful, .resultCorrection, .evaluationDispute].contains(signal),
            let state = try readState(db, jobID: promotion.inputs.identity.jobID),
            let row = try trialRow(db, trialID: promotion.inputs.identity.trialID)
      else {
        return false
      }
      let positives = promotion.cohort.filter { support in
        support.outcome == .positive
      }
      let kind: String = event["subject_kind"]
      let digest: String = event["subject_digest"]
      let affected = positives.filter { support in
        (kind == FeedbackSubjectKind.run.rawValue && digest == String(support.runID))
          || (kind == FeedbackSubjectKind.evaluation.rawValue && support.evaluationRequired
            && digest == support.evaluationDigest?.rawValue)
      }
      guard affected.isEmpty == false else {
        return false
      }
      let trial = try strictTrial(db, row: row, currentState: nil)
      var remaining = 0
      var affectedWithdrawn = false
      for support in positives {
        let projected = try authoritativeAssignment(
          db,
          runID: support.runID,
          trial: trial,
          currentState: state
        )
        let valid =
          projected.resolvedEvidence?.outcome == .positive
          && projected.resolvedEvidence?.hardVetoes.isEmpty == true
        if valid {
          remaining += 1
        } else if affected.contains(support) {
          affectedWithdrawn = true
        }
      }
      return affectedWithdrawn && remaining < 2
    }
  }

  static func effectiveOwnerEvent(
    _ db: Database,
    id: Int64,
    promotion: DecisionReceipt
  ) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT event.signal, event.subject_kind, event.subject_digest
        FROM feedback_events AS event
        WHERE event.event_id = ? AND event.job_id = ? AND event.learning_epoch = ?
          AND event.actor = ?
          AND NOT EXISTS (SELECT 1 FROM feedback_events AS successor
            WHERE successor.supersedes = event.event_id)
        """,
      arguments: [
        id,
        promotion.inputs.identity.jobID,
        promotion.inputs.identity.epoch.value,
        AuditActor.owner.rawValue,
      ]
    )
  }
}
