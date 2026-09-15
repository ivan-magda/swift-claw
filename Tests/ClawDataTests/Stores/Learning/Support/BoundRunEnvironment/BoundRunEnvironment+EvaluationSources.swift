import ClawCore
import Foundation
import GRDB

@testable import ClawData

enum EvaluationCorruption: CaseIterable {
  case missing
  case duplicate
  case digest
  case job
  case epoch
  case evidence
  case outcome
  case issueCodes
  case duplicateIssueCode
  case rubric
  case prompt
  case schema
  case compatibility
  case createdAt
}

enum EvaluatorSourceCorruption: CaseIterable {
  case orphanEvaluation
  case startedWithEvaluation
  case failedWithEvaluation
  case pendingFailure
  case claimedCallIdentity
  case startedMissingCarrier
  case startedMissingRoute
  case startedMissingProviderCall
  case startedNegativeTokens
  case startedNegativeCost
  case startedClosedReservation
  case succeededFailure
  case succeededMissingCarrier
  case succeededMissingRoute
  case succeededMissingProviderCall
  case succeededNonzeroTokens
  case succeededNonzeroCost
  case succeededMissingReservation
  case succeededOpenReservation
  case failedMissingFailure
  case failedWrongFailure
  case failedNoCallWrongFailure
  case failedNoCallCallIdentity
  case interruptedFailure
  case interruptedOpenReservation
  case unknownFailure
  case job
  case epoch
  case phase
  case sourceDigest
  case keyDigest
  case attemptGeneration
  case supersedes
}

extension BoundRunEnvironment {
  func apply(_ corruption: EvaluationCorruption, runID: Int64) throws {
    try queue.write { db in
      switch corruption {
      case .missing:
        try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
      case .duplicate:
        try db.execute(
          sql: """
          INSERT INTO learning_evaluations(evaluation_digest, job_id, learning_epoch, run_id,
            evidence_digest, outcome, issue_codes, rubric_version, evaluator_prompt_version,
            evaluator_schema_version, compatibility_digest, created_at)
          SELECT ?, job_id, learning_epoch, run_id, evidence_digest, outcome, issue_codes,
            rubric_version, evaluator_prompt_version, evaluator_schema_version,
            compatibility_digest, created_at
          FROM learning_evaluations WHERE run_id = ?
          """,
          arguments: [String(repeating: "f", count: 64), runID]
        )
      case .digest:
        try updateEvaluation(
          db,
          runID: runID,
          column: "evaluation_digest",
          value: String(repeating: "f", count: 64)
        )
      case .job: try updateEvaluation(db, runID: runID, column: "job_id", value: 999)
      case .epoch: try updateEvaluation(db, runID: runID, column: "learning_epoch", value: 999)
      case .evidence:
        try updateEvaluation(
          db,
          runID: runID,
          column: "evidence_digest",
          value: String(repeating: "f", count: 64)
        )
      case .outcome: try updateEvaluation(db, runID: runID, column: "outcome", value: "unknown")
      case .issueCodes:
        try updateEvaluation(db, runID: runID, column: "issue_codes", value: "[\"z\",\"a\"]")
      case .duplicateIssueCode:
        try updateEvaluation(
          db,
          runID: runID,
          column: "issue_codes",
          value: "[\"duplicate\",\"duplicate\"]"
        )
      case .rubric: try updateEvaluation(db, runID: runID, column: "rubric_version", value: "999")
      case .prompt:
        try updateEvaluation(db, runID: runID, column: "evaluator_prompt_version", value: "999")
      case .schema:
        try updateEvaluation(db, runID: runID, column: "evaluator_schema_version", value: "999")
      case .compatibility:
        try updateEvaluation(
          db,
          runID: runID,
          column: "compatibility_digest",
          value: String(repeating: "f", count: 64)
        )
      case .createdAt:
        try db.execute(
          sql: "UPDATE learning_evaluations SET created_at = X'00' WHERE run_id = ?",
          arguments: [runID]
        )
      }
    }
  }

  func apply(
    _ corruption: EvaluatorSourceCorruption,
    operationID: LearningOperationID,
    runID: Int64
  ) throws {
    try queue.write { db in
      switch corruption {
      case .orphanEvaluation:
        try db.execute(
          sql: "DELETE FROM learning_operations WHERE operation_id = ?",
          arguments: [operationID.rawValue]
        )
      case .startedWithEvaluation:
        try updateOperation(
          db,
          id: operationID,
          assignments: [
            "state": LearningOperationState.started.rawValue,
            "reservation_state": LearningReservationState.open.rawValue,
            "reserved_tokens": 1,
            "reserved_cost_usd": 1.0,
          ]
        )
      case .failedWithEvaluation:
        try updateOperation(
          db,
          id: operationID,
          assignments: [
            "state": LearningOperationState.failed.rawValue,
            "failure_code": LearningOperationFailure.providerTerminal.rawValue,
          ]
        )
      case .pendingFailure:
        try makeNoCallOperation(
          db,
          id: operationID,
          runID: runID,
          state: .pending,
          failure: .budgetDenied,
          retainEvaluation: false
        )
      case .claimedCallIdentity:
        try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
        try updateOperation(
          db,
          id: operationID,
          assignments: ["state": LearningOperationState.claimed.rawValue]
        )
      case .startedMissingCarrier:
        try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
        try updateOperation(
          db,
          id: operationID,
          assignments: [
            "state": LearningOperationState.started.rawValue,
            "carrier_digest": nil,
            "reservation_state": LearningReservationState.open.rawValue,
          ]
        )
      case .startedMissingRoute:
        try makeStartedOperationCorruption(
          db,
          id: operationID,
          runID: runID,
          assignments: ["route": nil]
        )
      case .startedMissingProviderCall:
        try makeStartedOperationCorruption(
          db,
          id: operationID,
          runID: runID,
          assignments: ["provider_call_id": nil]
        )
      case .startedNegativeTokens:
        try makeStartedOperationCorruption(
          db,
          id: operationID,
          runID: runID,
          assignments: ["reserved_tokens": -1]
        )
      case .startedNegativeCost:
        try makeStartedOperationCorruption(
          db,
          id: operationID,
          runID: runID,
          assignments: ["reserved_cost_usd": -1.0]
        )
      case .startedClosedReservation:
        try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
        try updateOperation(
          db,
          id: operationID,
          assignments: ["state": LearningOperationState.started.rawValue]
        )
      case .succeededFailure:
        try updateOperation(
          db,
          id: operationID,
          assignments: ["failure_code": LearningOperationFailure.providerTerminal.rawValue]
        )
      case .succeededMissingCarrier:
        try updateOperation(db, id: operationID, assignments: ["carrier_digest": nil])
      case .succeededMissingRoute:
        try updateOperation(db, id: operationID, assignments: ["route": nil])
      case .succeededMissingProviderCall:
        try updateOperation(db, id: operationID, assignments: ["provider_call_id": nil])
      case .succeededNonzeroTokens:
        try updateOperation(db, id: operationID, assignments: ["reserved_tokens": 1])
      case .succeededNonzeroCost:
        try updateOperation(db, id: operationID, assignments: ["reserved_cost_usd": 1.0])
      case .succeededMissingReservation:
        try updateOperation(db, id: operationID, assignments: ["reservation_state": nil])
      case .succeededOpenReservation:
        try updateOperation(
          db,
          id: operationID,
          assignments: ["reservation_state": LearningReservationState.open.rawValue]
        )
      case .failedMissingFailure:
        try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
        try updateOperation(
          db,
          id: operationID,
          assignments: ["state": LearningOperationState.failed.rawValue, "failure_code": nil]
        )
      case .failedWrongFailure:
        try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
        try updateOperation(
          db,
          id: operationID,
          assignments: [
            "state": LearningOperationState.failed.rawValue,
            "failure_code": LearningOperationFailure.budgetDenied.rawValue,
          ]
        )
      case .failedNoCallWrongFailure:
        try makeNoCallOperation(
          db,
          id: operationID,
          runID: runID,
          state: .failedNoCall,
          failure: .providerTerminal,
          retainEvaluation: false
        )
      case .failedNoCallCallIdentity:
        try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
        try updateOperation(
          db,
          id: operationID,
          assignments: [
            "state": LearningOperationState.failedNoCall.rawValue,
            "failure_code": LearningOperationFailure.budgetDenied.rawValue,
          ]
        )
      case .interruptedFailure:
        try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
        try updateOperation(
          db,
          id: operationID,
          assignments: [
            "state": LearningOperationState.interruptedUnknown.rawValue,
            "failure_code": LearningOperationFailure.providerTerminal.rawValue,
          ]
        )
      case .interruptedOpenReservation:
        try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
        try updateOperation(
          db,
          id: operationID,
          assignments: [
            "state": LearningOperationState.interruptedUnknown.rawValue,
            "reservation_state": LearningReservationState.open.rawValue,
          ]
        )
      case .unknownFailure:
        try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
        try updateOperation(
          db,
          id: operationID,
          assignments: ["state": LearningOperationState.failed.rawValue, "failure_code": "unknown"]
        )
      case .job: try updateOperation(db, id: operationID, assignments: ["job_id": jobID + 1])
      case .epoch: try updateOperation(db, id: operationID, assignments: ["learning_epoch": 2])
      case .phase:
        try updateOperation(
          db,
          id: operationID,
          assignments: ["phase": LearningPhase.reflector.rawValue]
        )
      case .sourceDigest:
        try updateOperation(
          db,
          id: operationID,
          assignments: ["source_digest": String(repeating: "f", count: 64)]
        )
      case .keyDigest:
        try updateOperation(
          db,
          id: operationID,
          assignments: ["key_digest": String(repeating: "f", count: 64)]
        )
      case .attemptGeneration:
        try updateOperation(db, id: operationID, assignments: ["attempt_generation": 2])
      case .supersedes:
        try updateOperation(db, id: operationID, assignments: ["supersedes": operationID.rawValue])
      }
    }
  }

  func replaceInterruptedOperationWithFailed(_ id: LearningOperationID) throws {
    try queue.write { db in
      try updateOperation(
        db,
        id: id,
        assignments: [
          "state": LearningOperationState.failed.rawValue,
          "failure_code": LearningOperationFailure.providerTerminal.rawValue,
        ]
      )
    }
  }
}

// MARK: - Evaluator Source Mutations

private extension BoundRunEnvironment {
  func updateEvaluation(
    _ db: Database,
    runID: Int64,
    column: String,
    value: (any DatabaseValueConvertible)?
  ) throws {
    try db.execute(
      sql: "UPDATE learning_evaluations SET \(column) = ? WHERE run_id = ?",
      arguments: [value, runID]
    )
  }

  func makeNoCallOperation(
    _ db: Database,
    id: LearningOperationID,
    runID: Int64,
    state: LearningOperationState,
    failure: LearningOperationFailure,
    retainEvaluation: Bool
  ) throws {
    if retainEvaluation == false {
      try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
    }
    try updateOperation(
      db,
      id: id,
      assignments: [
        "state": state.rawValue,
        "failure_code": failure.rawValue,
        "carrier_digest": nil,
        "route": nil,
        "provider_call_id": nil,
        "reserved_tokens": 0,
        "reserved_cost_usd": 0.0,
        "reservation_state": LearningReservationState.closed.rawValue,
      ]
    )
  }

  func makeStartedOperationCorruption(
    _ db: Database,
    id: LearningOperationID,
    runID: Int64,
    assignments: [String: (any DatabaseValueConvertible)?]
  ) throws {
    try db.execute(sql: "DELETE FROM learning_evaluations WHERE run_id = ?", arguments: [runID])
    var source = assignments
    source["state"] = LearningOperationState.started.rawValue
    source["reservation_state"] =
      source["reservation_state"] ?? LearningReservationState.open.rawValue
    try updateOperation(db, id: id, assignments: source)
  }

  func updateOperation(
    _ db: Database,
    id: LearningOperationID,
    assignments: [String: (any DatabaseValueConvertible)?]
  ) throws {
    let ordered = assignments.sorted { left, right in
      left.key < right.key
    }
    let columns = ordered.map { assignment in
      "\(assignment.key) = ?"
    }.joined(separator: ", ")
    var arguments = StatementArguments(ordered.map(\.value))
    arguments += [id.rawValue]
    try db.execute(
      sql: "UPDATE learning_operations SET \(columns) WHERE operation_id = ?",
      arguments: arguments
    )
  }
}
