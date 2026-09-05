import ClawCore
import Foundation
import GRDB

// MARK: - Strict Assignment Sources

extension ScheduledLearningStoreGRDB {
  struct StrictEvidence {
    let digest: EvidenceDigest
    let eligibility: LearningEligibility
  }

  struct StrictAttempt {
    let operation: OperationRow
    let generation: Int
    let supersedes: LearningOperationID?
  }

  struct StrictEvaluation {
    let digest: EvaluationDigest
    let evaluation: LearningEvaluation
  }

  struct StrictEvaluatorSource {
    let attempt: StrictAttempt?
    let evaluation: StrictEvaluation?
  }

  static func strictEvidence(
    _ db: Database,
    runId: Int64,
    trial: LearningTrial
  ) throws -> StrictEvidence? {
    guard let evidence = try readEvidence(db, runId: runId) else {
      return nil
    }
    guard
      evidence.jobId == trial.jobId,
      evidence.epoch == trial.epoch
    else {
      throw StoreError.unexpected("assignment \(runId) has an unreadable evidence receipt")
    }
    return StrictEvidence(digest: evidence.digest, eligibility: evidence.eligibility)
  }

  static func strictEvaluatorSource(
    _ db: Database,
    runId: Int64,
    trial: LearningTrial,
    evidence: StrictEvidence
  ) throws -> StrictEvaluatorSource {
    let evaluations = try storedEvaluations(db, runId: runId)
    guard let attempt = try latestEvaluatorAttempt(db, trial: trial, evidence: evidence) else {
      guard evaluations.isEmpty else {
        throw StoreError.unexpected("evaluation has no exact evaluator operation")
      }
      return StrictEvaluatorSource(attempt: nil, evaluation: nil)
    }
    guard attempt.operation.state == .succeeded else {
      guard evaluations.isEmpty else {
        throw StoreError.unexpected("non-succeeded evaluator operation has an evaluation")
      }
      return StrictEvaluatorSource(attempt: attempt, evaluation: nil)
    }
    guard evaluations.count == 1, let stored = evaluations.first else {
      throw StoreError.unexpected("succeeded evaluator requires exactly one evaluation")
    }
    return StrictEvaluatorSource(
      attempt: attempt,
      evaluation: try strictEvaluation(
        db,
        runId: runId,
        trial: trial,
        evidence: evidence,
        operation: attempt.operation,
        stored: stored
      )
    )
  }
}

// MARK: - Evaluator Operation Lineage

private extension ScheduledLearningStoreGRDB {
  static func latestEvaluatorAttempt(
    _ db: Database,
    trial: LearningTrial,
    evidence: StrictEvidence
  ) throws -> StrictAttempt? {
    let key = exactEvaluatorKey(trial: trial, evidence: evidence)
    let rows = try evaluatorAttemptRows(db, key: key, trial: trial, evidence: evidence)
    var attempts: [StrictAttempt] = []
    for row in rows {
      guard
        let idRaw = SQLiteStoredValue.string(in: row, column: "operation_id"),
        let generation = SQLiteStoredValue.int(in: row, column: "attempt_generation"),
        generation > 0,
        let supersedesRaw = SQLiteStoredValue.nullableString(in: row, column: "supersedes"),
        idRaw == LearningOperationID(key: key.digest, attemptGeneration: generation).rawValue,
        let operation = try readOperation(db, id: LearningOperationID(rawValue: idRaw)),
        operation.jobId == trial.jobId,
        operation.epoch == trial.epoch,
        operation.phase == .evaluator,
        operation.sourceDigest == evidence.digest.rawValue,
        operation.keyDigest == key.digest
      else {
        throw StoreError.unexpected("evaluator operation lineage is unreadable")
      }
      try validateEvaluatorOperation(operation)
      attempts.append(
        StrictAttempt(
          operation: operation,
          generation: generation,
          supersedes: supersedesRaw.value.map(LearningOperationID.init(rawValue:))
        )
      )
    }
    for (offset, attempt) in attempts.enumerated() {
      guard attempt.generation == offset + 1 else {
        throw StoreError.unexpected("evaluator operation lineage has a generation gap")
      }
      let expectedPredecessor = offset == 0 ? nil : attempts[offset - 1].operation.id
      guard attempt.supersedes == expectedPredecessor else {
        throw StoreError.unexpected("evaluator operation lineage has a broken predecessor")
      }
      if offset < attempts.count - 1, attempt.operation.state != .interruptedUnknown {
        throw StoreError.unexpected("superseded evaluator operation did not end interrupted")
      }
    }
    return attempts.last
  }

  static func exactEvaluatorKey(
    trial: LearningTrial,
    evidence: StrictEvidence
  ) -> LearningOperationKey {
    LearningOperationKey(
      jobId: trial.jobId,
      epoch: trial.epoch,
      phase: .evaluator,
      sourceDigest: evidence.digest.rawValue,
      promptVersion: EvaluatorPrompt.v1.version,
      schemaVersion: EvaluatorOutput.currentSchemaVersion,
      rubricVersion: EvaluatorRubric.v1.version
    )
  }

  static func evaluatorAttemptRows(
    _ db: Database,
    key: LearningOperationKey,
    trial: LearningTrial,
    evidence: StrictEvidence
  ) throws -> [Row] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT operation_id, attempt_generation, supersedes
        FROM learning_operations
        WHERE key_digest = ? OR (
          job_id = ? AND learning_epoch = ? AND phase = ? AND source_digest = ?
        )
        ORDER BY attempt_generation
        """,
      arguments: [
        key.digest.rawValue,
        trial.jobId,
        trial.epoch.value,
        LearningPhase.evaluator.rawValue,
        evidence.digest.rawValue,
      ]
    )
  }

  static func validateEvaluatorOperation(_ operation: OperationRow) throws {
    switch operation.state {
    case .pending, .claimed:
      guard
        operation.failure == nil,
        operation.carrierDigest == nil,
        operation.route == nil,
        operation.providerCallID == nil,
        operation.reservedTokens == nil,
        operation.reservedCostUSD == nil,
        operation.reservationState == nil
      else {
        throw StoreError.unexpected("live evaluator operation has an invalid no-call shape")
      }
    case .started:
      guard
        operation.failure == nil,
        let carrier = operation.carrierDigest,
        carrier.rawValue.isEmpty == false
      else {
        throw StoreError.unexpected("started evaluator operation has an invalid source shape")
      }
      _ = try startedOperationReservation(operation)
    case .succeeded, .interruptedUnknown:
      guard operation.failure == nil, terminalCallShapeIsValid(operation) else {
        throw StoreError.unexpected("terminal evaluator operation has an invalid call shape")
      }
    case .failed:
      guard
        operation.failure == .schemaInvalid || operation.failure == .providerTerminal,
        terminalCallShapeIsValid(operation)
      else {
        throw StoreError.unexpected("failed evaluator operation has an invalid call shape")
      }
    case .failedNoCall:
      let failureIsValid =
        operation.failure == .budgetDenied
        || operation.failure == .carrierPolicyDenied
        || operation.failure == .staleEpoch
      guard
        failureIsValid,
        operation.carrierDigest == nil,
        operation.route == nil,
        operation.providerCallID == nil,
        operation.reservedTokens == 0,
        operation.reservedCostUSD == 0,
        operation.reservationState == LearningReservationState.closed.rawValue
      else {
        throw StoreError.unexpected("failed evaluator operation has an invalid no-call shape")
      }
    }
  }

  static func terminalCallShapeIsValid(_ operation: OperationRow) -> Bool {
    guard
      let carrier = operation.carrierDigest,
      carrier.rawValue.isEmpty == false,
      let route = operation.route,
      route.isEmpty == false,
      let providerCallID = operation.providerCallID,
      providerCallID.rawValue.isEmpty == false
    else {
      return false
    }
    return operation.reservedTokens == 0
      && operation.reservedCostUSD == 0
      && operation.reservationState == LearningReservationState.closed.rawValue
  }
}

// MARK: - Exact Evaluation

private extension ScheduledLearningStoreGRDB {
  static func strictEvaluation(
    _ db: Database,
    runId: Int64,
    trial: LearningTrial,
    evidence: StrictEvidence,
    operation: OperationRow,
    stored: StoredEvaluationProjection
  ) throws -> StrictEvaluation {
    guard
      stored.jobId == trial.jobId,
      stored.epoch == trial.epoch,
      stored.runId == runId,
      stored.evidenceDigest == evidence.digest,
      stored.evaluation.evaluator.rubricVersion == EvaluatorRubric.v1.version,
      stored.evaluation.evaluator.promptVersion == EvaluatorPrompt.v1.version,
      stored.evaluation.evaluator.schemaVersion == EvaluatorOutput.currentSchemaVersion,
      let compatibility = try readCompatibility(db, runId: runId),
      let binding = try readBinding(db, runId: runId)
    else {
      throw StoreError.unexpected("assignment \(runId) has an unreadable evaluation")
    }
    let compatibilityDigest = compatibility.digest(
      binding: binding,
      terminalRoute: try readTerminalRoute(db, runId: runId),
      evaluator: stored.evaluation.evaluator
    )
    guard compatibilityDigest == stored.compatibilityDigest else {
      throw StoreError.unexpected("assignment \(runId) evaluation surface does not match")
    }
    let expectedDigest = digest(
      operation: operation,
      runId: runId,
      evaluation: stored.evaluation,
      issueCodes: stored.issueCodesJSON,
      compatibility: compatibilityDigest
    )
    guard expectedDigest == stored.digest else {
      throw StoreError.unexpected("assignment \(runId) evaluation digest does not match")
    }
    return StrictEvaluation(digest: expectedDigest, evaluation: stored.evaluation)
  }
}
