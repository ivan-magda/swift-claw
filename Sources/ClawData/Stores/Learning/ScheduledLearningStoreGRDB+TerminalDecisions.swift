import ClawCore
import Foundation
import GRDB

// MARK: - Terminal Trial Decisions

extension ScheduledLearningStoreGRDB {
  public func applyTrialDecision(
    _ decision: TrialDecision,
    trial: LearningTrial,
    feedbackRevision: FeedbackRevision,
    now: Date
  ) throws(StoreError) -> DecisionReceipt? {
    switch decision {
    case .wait, .closeAssignment:
      return nil
    case .promote, .fallback:
      break
    }
    let inputs = TrialDecisionInputs(trial: trial, feedbackRevision: feedbackRevision)
    return try database.writeMapping { db -> DecisionReceipt? in
      if let replay = try Self.terminalReceipt(db, inputs: inputs) {
        return replay
      }
      guard let row = try Self.trialRow(db, trialId: trial.trialId) else {
        return nil
      }
      let current = try Self.readState(db, jobId: trial.jobId)
      let stored = try Self.strictTrial(db, row: row, currentState: nil)
      guard
        let current,
        let job = try Self.admissionJob(db, jobId: trial.jobId),
        job.hasRecurrence, job.status != .cancelled,
        current.epoch == inputs.identity.epoch,
        stored.identity == inputs.identity,
        stored.candidateDigest == inputs.candidateDigest,
        stored.replacementDigest == inputs.replacementDigest,
        stored.baseDigest == inputs.baseDigest, stored.baseRevision == inputs.baseRevision,
        current.stableDigest == inputs.baseDigest,
        current.stableRevision == inputs.baseRevision,
        current.feedbackRevision == inputs.feedbackRevision,
        stored.algorithm == inputs.algorithm, inputs.algorithm == .v1,
        stored.state == .open || stored.state == .draining
      else {
        return try Self.finishTrial(
          db,
          trial: stored,
          inputs: inputs,
          result: .stale,
          reason: LearningDecisionResult.stale.rawValue,
          cohort: [],
          revision: current?.stableRevision ?? inputs.baseRevision,
          closesTrial: stored.identity == inputs.identity,
          now: now
        )
      }
      let runIds = try Self.assignmentRunIds(db, trialId: stored.trialId)
      guard runIds.count == stored.consumedAssignments else {
        throw StoreError.unexpected("terminal cohort does not match consumed assignments")
      }
      let assignments = try runIds.map { runId in
        try Self.authoritativeAssignment(db, runId: runId, trial: stored, currentState: current)
      }
      let actual = TrialPolicy.decide(trial: stored, assignments: assignments, now: now)
      let result: LearningDecisionResult
      let reason: String
      switch actual {
      case .promote:
        guard decision == .promote else {
          return nil
        }
        guard let candidate = try Self.readCandidateArtifact(db, digest: stored.candidateDigest),
          try Self.sourceBindingsAreCurrent(db, artifact: candidate, state: current)
        else {
          return try Self.finishTrial(
            db,
            trial: stored,
            inputs: inputs,
            result: .stale,
            reason: LearningDecisionResult.stale.rawValue,
            cohort: assignments.map(DecisionSupport.init),
            revision: current.stableRevision,
            closesTrial: true,
            now: now
          )
        }
        result = .promoted
        reason = LearningDecisionResult.promoted.rawValue
      case .fallback(let fallback):
        result = .fallback
        reason = fallback.rawValue
      case .wait, .closeAssignment:
        return nil
      }
      let revision =
        result == .promoted
        ? StableRevision(current.stableRevision.value + 1) : current.stableRevision
      return try Self.finishTrial(
        db,
        trial: stored,
        inputs: inputs,
        result: result,
        reason: reason,
        cohort: assignments.map(DecisionSupport.init),
        revision: revision,
        closesTrial: true,
        now: now
      )
    }
  }
}

// MARK: - Shared Terminal Transaction

extension ScheduledLearningStoreGRDB {
  // swiftlint:disable:next function_parameter_count
  static func finishTrial(
    _ db: Database,
    trial: LearningTrial,
    inputs: TrialDecisionInputs,
    result: LearningDecisionResult,
    reason: String,
    cohort: [DecisionSupport],
    revision: StableRevision,
    closesTrial: Bool,
    now: Date
  ) throws -> DecisionReceipt {
    let record = LearningDecisionRecord(
      result: result,
      reason: reason,
      cohort: cohort,
      stableRevision: revision
    )
    let receipt = try persistTerminalDecision(db, inputs: inputs, record: record, now: now)
    if result == .promoted {
      try db.execute(
        sql: """
          UPDATE job_learning_state SET stable_lesson_set_digest = ?, stable_revision = ?
          WHERE job_id = ? AND learning_epoch = ? AND stable_lesson_set_digest = ?
            AND stable_revision = ? AND feedback_revision = ?
          """,
        arguments: [
          inputs.replacementDigest.rawValue, revision.value, trial.jobId, trial.epoch.value,
          inputs.baseDigest.rawValue, inputs.baseRevision.value, inputs.feedbackRevision.value,
        ]
      )
      guard db.changesCount == 1 else {
        throw StoreError.unexpected("promotion CAS changed inside its write transaction")
      }
    }
    if closesTrial, trial.state == .open || trial.state == .draining {
      let state: LearningTrialState = result == .promoted ? .promoted : .fellBack
      try db.execute(
        sql: """
          UPDATE learning_trials SET state = ?, close_reason = ?
          WHERE trial_id = ? AND job_id = ? AND learning_epoch = ? AND generation = ?
            AND state IN (?, ?)
          """,
        arguments: [
          state.rawValue, reason, trial.trialId, trial.jobId, trial.epoch.value, trial.generation,
          LearningTrialState.open.rawValue, LearningTrialState.draining.rawValue,
        ]
      )
      try db.execute(
        sql: """
          UPDATE job_learning_state SET open_trial_id = NULL
          WHERE job_id = ? AND learning_epoch = ? AND open_trial_id = ?
          """,
        arguments: [trial.jobId, trial.epoch.value, trial.trialId]
      )
    }
    return receipt
  }

  static func terminalFallback(
    _ db: Database,
    trialId: Int64,
    now: Date
  ) throws {
    guard let row = try trialRow(db, trialId: trialId) else {
      return
    }
    let trial = try strictTrial(db, row: row, currentState: nil)
    guard trial.state == .open || trial.state == .draining,
      let state = try readState(db, jobId: trial.jobId)
    else {
      return
    }
    let assignments = try assignmentRunIds(db, trialId: trialId).map { runId in
      try authoritativeAssignment(db, runId: runId, trial: trial, currentState: state)
    }
    _ = try finishTrial(
      db,
      trial: trial,
      inputs: TrialDecisionInputs(trial: trial, feedbackRevision: state.feedbackRevision),
      result: .fallback,
      reason: TrialFallbackReason.hardVeto.rawValue,
      cohort: assignments.map(DecisionSupport.init),
      revision: state.stableRevision,
      closesTrial: true,
      now: now
    )
  }

  static func persistTerminalDecision(
    _ db: Database,
    inputs: TrialDecisionInputs,
    record: LearningDecisionRecord,
    now: Date
  ) throws -> DecisionReceipt {
    let kind: LearningDecisionKind = record.rollbackTrigger == nil ? .trial : .rollback
    let id = try insertDecision(
      db,
      kind: kind.rawValue,
      jobId: inputs.identity.jobId,
      epoch: inputs.identity.epoch,
      inputs: inputs,
      result: record,
      algorithm: inputs.algorithm,
      now: now
    )
    return DecisionReceipt(decisionId: id, inputs: inputs, record: record)
  }

  static func terminalReceipt(_ db: Database, inputs: TrialDecisionInputs) throws
    -> DecisionReceipt?
  {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT decision_id, inputs, result FROM learning_decisions
          WHERE kind = ? AND job_id = ? AND learning_epoch = ? AND inputs = ?
          ORDER BY decision_id LIMIT 1
          """,
        arguments: [
          LearningDecisionKind.trial.rawValue, inputs.identity.jobId, inputs.identity.epoch.value,
          try canonicalDecisionJSON(inputs),
        ]
      )
    else {
      return nil
    }
    return try decodeTerminalReceipt(row)
  }

  static func decodeTerminalReceipt(_ row: Row) throws -> DecisionReceipt {
    DecisionReceipt(
      decisionId: row["decision_id"],
      inputs: try decodeCanonicalDecision(row["inputs"]),
      record: try decodeCanonicalDecision(row["result"])
    )
  }
}
