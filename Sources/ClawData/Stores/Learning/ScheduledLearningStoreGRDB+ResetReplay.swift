import ClawCore
import Foundation
import GRDB

// MARK: - Logical Replay

extension ScheduledLearningStoreGRDB {
  struct ResetDecisionRecord {
    let decisionID: Int64
    let jobID: Int64
    let epoch: LearningEpoch
    let inputsJSON: String
    let resultJSON: String
    let algorithm: LearningAlgorithm
    let decidedAt: Date
  }

  static func resetReceipt(_ db: Database, record: ResetDecisionRecord) throws -> ResetReceipt? {
    guard record.decisionID > 0, record.jobID > 0, record.epoch.value > 0, record.algorithm == .v1
    else {
      return nil
    }
    let inputs: LearningResetDecisionInputs
    let result: LearningResetDecisionResult
    do {
      inputs = try decodeCanonicalDecision(record.inputsJSON)
      result = try decodeCanonicalDecision(record.resultJSON)
    } catch let error as StoreError {
      guard case .unexpected = error else {
        throw error
      }
      return nil
    }
    guard inputs.oldEpoch.value > 0,
          inputs.oldEpoch.value < Int64.max,
          inputs.oldEpoch.next() == result.newEpoch,
          result.newEpoch == record.epoch,
          isCanonicalDigest(inputs.oldStableDigest.rawValue),
          inputs.oldStableRevision.value >= 0,
          inputs.oldStableRevision.value < Int64.max,
          inputs.oldStableRevision.next() == result.newStableRevision,
          inputs.feedbackRevisionAtCut.value >= 0,
          inputs.priorOpenTrialID.map({
        $0 > 0
      }) ?? true,
          result.emptyStableDigest == LessonSet.empty(jobID: record.jobID).digest,
          result.invalidatedTargetCount >= 0,
          result.invalidatedChallengeCount >= 0,
          resetTrialsAreSortedAndUnique(result.closedTrials),
          resetOperationsAreSortedAndUnique(result.staleNoCallOperationIDs),
          resetOperationsAreSortedAndUnique(result.inFlightOperationIDs),
          Set(result.staleNoCallOperationIDs).isDisjoint(with: result.inFlightOperationIDs),
          try resetTrialRowsMatch(db, result.closedTrials, jobID: record.jobID),
          try resetOperationRowsMatch(
            db,
            staleNoCall: result.staleNoCallOperationIDs,
            inFlight: result.inFlightOperationIDs,
            jobID: record.jobID,
            before: result.newEpoch
          )
    else {
      return nil
    }
    return ResetReceipt(
      decisionID: record.decisionID,
      jobID: record.jobID,
      algorithm: record.algorithm,
      decidedAt: record.decidedAt,
      inputs: inputs,
      result: result
    )
  }
}

// MARK: - Reset Replay Expectations

private extension ScheduledLearningStoreGRDB {
  enum ResetOperationExpectation {
    case staleNoCall
    case inFlight

    var allowedStates: [LearningOperationState] {
      switch self {
      case .staleNoCall:
        [.failedNoCall]
      case .inFlight:
        [.started, .succeeded, .failed, .interruptedUnknown]
      }
    }
  }

  static let resetActivityTables = [
    "run_learning_bindings",
    "run_compatibility",
    "learning_evidence",
    "learning_operations",
    "learning_evaluations",
    "feedback_targets",
    "feedback_challenges",
    "feedback_events",
    "learning_candidates",
    "learning_trials",
    "trial_assignments",
  ]
}

extension ScheduledLearningStoreGRDB {
  static func cleanResetReceipt(_ db: Database, state: JobLearningState) throws -> ResetReceipt? {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT decision_id, kind, job_id, learning_epoch, inputs, result, algorithm, decided_at
        FROM learning_decisions WHERE job_id = ? AND learning_epoch = ?
        ORDER BY decision_id
        """,
      arguments: [state.jobID, state.epoch.value]
    )
    guard rows.count == 1, let row = rows.first else {
      return nil
    }
    guard SQLiteStoredValue.string(in: row, column: "kind") == ResetReceipt.kind,
          let decisionID = SQLiteStoredValue.int64(in: row, column: "decision_id"),
          SQLiteStoredValue.int64(in: row, column: "job_id") == state.jobID,
          let epochValue = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
          let inputsJSON = SQLiteStoredValue.string(in: row, column: "inputs"),
          let resultJSON = SQLiteStoredValue.string(in: row, column: "result"),
          let algorithmRaw = SQLiteStoredValue.string(in: row, column: "algorithm"),
          let decidedEpoch = SQLiteStoredValue.int64(in: row, column: "decided_at"),
          let decidedAt = EpochSecondCodec.date(fromEpoch: decidedEpoch),
          let receipt = try resetReceipt(
            db,
            record: ResetDecisionRecord(
              decisionID: decisionID,
              jobID: state.jobID,
              epoch: LearningEpoch(epochValue),
              inputsJSON: inputsJSON,
              resultJSON: resultJSON,
              algorithm: LearningAlgorithm(rawValue: algorithmRaw),
              decidedAt: decidedAt
            )
          ),
          resetStateMatches(state, receipt: receipt),
          try resetEffectsAreClean(db, state: state, receipt: receipt)
    else {
      return nil
    }
    return receipt
  }
}

// MARK: - Reset Replay Validation

private extension ScheduledLearningStoreGRDB {
  static func resetStateMatches(_ state: JobLearningState, receipt: ResetReceipt) -> Bool {
    state.epoch == receipt.result.newEpoch && state.stableDigest == receipt.result.emptyStableDigest
      && state.stableRevision == receipt.result.newStableRevision
      && state.feedbackRevision == receipt.inputs.feedbackRevisionAtCut && state.openTrialID == nil
  }

  static func resetEffectsAreClean(
    _ db: Database,
    state: JobLearningState,
    receipt: ResetReceipt
  ) throws -> Bool {
    let empty = LessonSet.empty(jobID: state.jobID)
    guard let emptyRow = try Row.fetchOne(
      db,
      sql: """
          SELECT job_id, digest, schema_version, canonical_bytes, source
          FROM lesson_sets WHERE job_id = ? AND digest = ?
          """,
      arguments: [state.jobID, empty.digest.rawValue]
    ),
          canonicalEmptySetMatches(emptyRow, set: empty),
          try rowExists(
            db,
            sql: """
          SELECT EXISTS(SELECT 1 FROM learning_trials
            WHERE job_id = ? AND state IN (?, ?))
          """,
            arguments: [
              state.jobID,
              LearningTrialState.open.rawValue,
              LearningTrialState.draining.rawValue,
            ]
          ) == false,
          try rowExists(
            db,
            sql:
          "SELECT EXISTS(SELECT 1 FROM feedback_targets WHERE job_id = ? AND consumed_at IS NULL)",
            arguments: [state.jobID]
          ) == false,
          try rowExists(
            db,
            sql: """
          SELECT EXISTS(SELECT 1 FROM feedback_challenges
            WHERE job_id = ? AND superseded_by IS NULL AND consumed_at IS NULL)
          """,
            arguments: [state.jobID]
          ) == false,
          try rowExists(
            db,
            sql: """
          SELECT EXISTS(SELECT 1 FROM learning_operations
            WHERE job_id = ? AND learning_epoch < ? AND state IN (?, ?))
          """,
            arguments: [
              state.jobID,
              state.epoch.value,
              LearningOperationState.pending.rawValue,
              LearningOperationState.claimed.rawValue,
            ]
          ) == false,
          try startedOperationsAreCovered(db, state: state, receipt: receipt),
          try currentEpochHasNoPostResetActivity(db, state: state)
    else {
      return false
    }
    return true
  }

  static func startedOperationsAreCovered(
    _ db: Database,
    state: JobLearningState,
    receipt: ResetReceipt
  ) throws -> Bool {
    let started = try resetOperationIDs(
      db,
      jobID: state.jobID,
      before: state.epoch,
      states: [.started]
    )
    return Set(started).isSubset(of: receipt.result.inFlightOperationIDs)
  }

  static func currentEpochHasNoPostResetActivity(
    _ db: Database,
    state: JobLearningState
  ) throws -> Bool {
    for table in resetActivityTables {
      let count = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM \(table) WHERE job_id = ? AND learning_epoch = ?",
        arguments: [state.jobID, state.epoch.value]
      )
      guard count == 0 else {
        return false
      }
    }
    return true
  }

  static func resetTrialsAreSortedAndUnique(_ trials: [ResetTrialIdentity]) -> Bool {
    trials.elementsAreInStrictAscendingOrder(by: \.trialID)
  }

  static func resetOperationsAreSortedAndUnique(_ operations: [LearningOperationID]) -> Bool {
    operations.allSatisfy {
      $0.rawValue.isEmpty == false
    }
      && operations.elementsAreInStrictAscendingOrder(by: \.rawValue)
  }

  static func resetTrialRowsMatch(
    _ db: Database,
    _ trials: [ResetTrialIdentity],
    jobID: Int64
  ) throws -> Bool {
    for trial in trials {
      guard trial.jobID == jobID,
            trial.trialID > 0,
            trial.epoch.value > 0,
            trial.generation > 0,
            isCanonicalDigest(trial.baseDigest.rawValue),
            isCanonicalDigest(trial.candidateDigest.rawValue),
            trial.algorithm == .v1,
            let row = try Row.fetchOne(
              db,
              sql: """
            SELECT job_id, learning_epoch, generation, base_digest, candidate_digest, state,
              close_reason, algorithm
            FROM learning_trials WHERE trial_id = ?
            """,
              arguments: [trial.trialID]
            ),
            SQLiteStoredValue.int64(in: row, column: "job_id") == trial.jobID,
            SQLiteStoredValue.int64(in: row, column: "learning_epoch") == trial.epoch.value,
            SQLiteStoredValue.int(in: row, column: "generation") == trial.generation,
            SQLiteStoredValue.string(in: row, column: "base_digest") == trial.baseDigest.rawValue,
            SQLiteStoredValue.string(in: row, column: "candidate_digest")
            == trial.candidateDigest.rawValue,
            SQLiteStoredValue.string(
              in: row,
              column: "state"
            ) == LearningTrialState.closed.rawValue,
            SQLiteStoredValue.string(in: row, column: "close_reason")
            == LearningTrialCloseReason.learningReset.rawValue,
            SQLiteStoredValue.string(in: row, column: "algorithm") == trial.algorithm.rawValue
      else {
        return false
      }
    }
    return true
  }

  static func resetOperationRowsMatch(
    _ db: Database,
    staleNoCall: [LearningOperationID],
    inFlight: [LearningOperationID],
    jobID: Int64,
    before newEpoch: LearningEpoch
  ) throws -> Bool {
    for id in staleNoCall {
      guard try resetOperationMatches(
        db,
        id: id,
        jobID: jobID,
        before: newEpoch,
        expectation: .staleNoCall
      )
      else {
        return false
      }
    }
    for id in inFlight {
      guard try resetOperationMatches(
        db,
        id: id,
        jobID: jobID,
        before: newEpoch,
        expectation: .inFlight
      )
      else {
        return false
      }
    }
    return true
  }

  static func resetOperationMatches(
    _ db: Database,
    id: LearningOperationID,
    jobID: Int64,
    before newEpoch: LearningEpoch,
    expectation: ResetOperationExpectation
  ) throws -> Bool {
    guard let row = try Row.fetchOne(
      db,
      sql: """
          SELECT job_id, learning_epoch, state, failure_code, reserved_tokens,
            reserved_cost_usd, reservation_state
          FROM learning_operations WHERE operation_id = ?
          """,
      arguments: [id.rawValue]
    ),
          SQLiteStoredValue.int64(in: row, column: "job_id") == jobID,
          let epoch = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
          epoch < newEpoch.value,
          let stateRaw = SQLiteStoredValue.string(in: row, column: "state"),
          let state = LearningOperationState(rawValue: stateRaw),
          expectation.allowedStates.contains(state)
    else {
      return false
    }
    guard case .staleNoCall = expectation else {
      if state == .started {
        guard let operation = try readOperation(db, id: id) else {
          return false
        }
        _ = try startedOperationReservation(operation)
      }
      return true
    }
    return SQLiteStoredValue.string(in: row, column: "failure_code")
      == LearningOperationFailure.staleEpoch.rawValue
      && SQLiteStoredValue.int(in: row, column: "reserved_tokens") == 0
      && SQLiteStoredValue.double(in: row, column: "reserved_cost_usd") == 0
      && SQLiteStoredValue.string(in: row, column: "reservation_state")
        == LearningReservationState.closed.rawValue
  }

  static func rowExists(_ db: Database, sql: String, arguments: StatementArguments) throws -> Bool {
    try Bool.fetchOne(db, sql: sql, arguments: arguments) ?? true
  }
}

// MARK: - Strict Ordering

private extension Array {
  func elementsAreInStrictAscendingOrder<Value: Comparable>(
    by keyPath: KeyPath<Element, Value>
  ) -> Bool {
    zip(self, dropFirst()).allSatisfy { left, right in
      left[keyPath: keyPath] < right[keyPath: keyPath]
    }
  }
}
