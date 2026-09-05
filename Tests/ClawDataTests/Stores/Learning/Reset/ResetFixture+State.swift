import ClawCore
import Foundation
import GRDB

@testable import ClawData

extension ResetFixture {
  struct OperationProjection: Equatable {
    let state: LearningOperationState
    let failure: LearningOperationFailure?
    let reservation: LearningReservationState?
    let reservedTokens: Int?
    let reservedCostUSD: Double?
    let route: String?
    let providerCallId: String?

    static let staleNoCall = OperationProjection(
      state: .failedNoCall,
      failure: .staleEpoch,
      reservation: .closed,
      reservedTokens: 0,
      reservedCostUSD: 0,
      route: nil,
      providerCallId: nil
    )

    static let started = OperationProjection(
      state: .started,
      failure: nil,
      reservation: .open,
      reservedTokens: 300,
      reservedCostUSD: 0.5,
      route: "route",
      providerCallId: "provider-secret-call"
    )

    static let claimed = OperationProjection(
      state: .claimed,
      failure: nil,
      reservation: nil,
      reservedTokens: nil,
      reservedCostUSD: nil,
      route: nil,
      providerCallId: nil
    )
  }

  struct AuditProjection {
    let actor: String
    let action: String
    let tool: String?
    let args: String
    let resultSize: Int
    let decision: String
    let runId: Int64?
    let sessionId: Int64?
  }

  struct ProcessedUpdateProjection: Equatable {
    let updateId: Int64
    let claimedAt: Date
  }

  struct AbsenceProjection: Equatable {
    let processedUpdates: [ProcessedUpdateProjection]
    let learningStateCount: Int
    let lessonSetCount: Int
    let resetDecisionCount: Int
    let resetAuditCount: Int
  }

  struct DurableProjection: Equatable {
    let tables: [DurableTableProjection]
  }

  struct DurableTableProjection: Equatable {
    let name: String
    let columns: [String]
    let rows: [[DatabaseValue]]
  }

  func state() throws -> JobLearningState {
    try env.currentLearningState()
  }

  func closedTrialIds() throws -> [Int64] {
    try trialIds(state: .closed)
  }

  func closedTrialReasons() throws -> [String] {
    try env.queue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT close_reason FROM learning_trials WHERE job_id = ? ORDER BY trial_id",
        arguments: [env.jobId]
      )
      return try rows.map { row in
        guard let reason = SQLiteStoredValue.string(in: row, column: "close_reason") else {
          throw StoreError.unexpected("fixture trial close reason is unreadable")
        }
        return reason
      }
    }
  }

  func liveTrialIds() throws -> [Int64] {
    try env.queue.read { db in
      try Int64.fetchAll(
        db,
        sql: """
          SELECT trial_id FROM learning_trials
          WHERE job_id = ? AND state IN (?, ?) ORDER BY trial_id
          """,
        arguments: [
          env.jobId,
          LearningTrialState.open.rawValue,
          LearningTrialState.draining.rawValue,
        ]
      )
    }
  }

  func trialIds(state: LearningTrialState) throws -> [Int64] {
    try env.queue.read { db in
      try Int64.fetchAll(
        db,
        sql: """
          SELECT trial_id FROM learning_trials
          WHERE job_id = ? AND state = ? ORDER BY trial_id
          """,
        arguments: [env.jobId, state.rawValue]
      )
    }
  }

  func unconsumedTargetCount(jobId: Int64) throws -> Int {
    try count(
      "feedback_targets",
      predicate: "job_id = ? AND consumed_at IS NULL",
      arguments: [jobId]
    )
  }

  func targetConsumptionEpochs(jobId: Int64) throws -> [Int64] {
    try consumptionEpochs(
      table: "feedback_targets",
      id: "nonce",
      predicate: "job_id = ?",
      arguments: [jobId]
    )
  }

  func liveChallengeCount(jobId: Int64) throws -> Int {
    try count(
      "feedback_challenges",
      predicate: "job_id = ? AND superseded_by IS NULL AND consumed_at IS NULL",
      arguments: [jobId]
    )
  }

  func challengeConsumptionEpochs(jobId: Int64) throws -> [Int64] {
    try consumptionEpochs(
      table: "feedback_challenges",
      id: "challenge_id",
      predicate: "job_id = ? AND superseded_by IS NULL",
      arguments: [jobId]
    )
  }

  func unconsumedSupersededChallengeCount() throws -> Int {
    try count(
      "feedback_challenges",
      predicate: "job_id = ? AND superseded_by IS NOT NULL AND consumed_at IS NULL",
      arguments: [env.jobId]
    )
  }

  func operation(_ id: String) throws -> OperationProjection? {
    try env.queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT state, failure_code, reservation_state, reserved_tokens, reserved_cost_usd,
              route, provider_call_id
            FROM learning_operations WHERE operation_id = ?
            """,
          arguments: [id]
        ),
        let state = LearningOperationState(rawValue: row["state"])
      else {
        return nil
      }
      let failureRaw: String? = row["failure_code"]
      let reservationRaw: String? = row["reservation_state"]
      return OperationProjection(
        state: state,
        failure: failureRaw.flatMap(LearningOperationFailure.init(rawValue:)),
        reservation: reservationRaw.flatMap(LearningReservationState.init(rawValue:)),
        reservedTokens: row["reserved_tokens"],
        reservedCostUSD: row["reserved_cost_usd"],
        route: row["route"],
        providerCallId: row["provider_call_id"]
      )
    }
  }

  func resetAudit() throws -> AuditProjection {
    let row = try env.queue.read { db in
      try Row.fetchOne(
        db,
        sql: """
          SELECT actor, action, tool, args_redacted, result_size, decision, run_id, session_id
          FROM audit_events WHERE action = ?
          """,
        arguments: [AuditAction.learningReset.rawValue]
      )
    }
    guard let row else {
      throw StoreError.unexpected("fixture reset audit is missing")
    }
    return AuditProjection(
      actor: row["actor"],
      action: row["action"],
      tool: row["tool"],
      args: row["args_redacted"],
      resultSize: row["result_size"],
      decision: row["decision"],
      runId: row["run_id"],
      sessionId: row["session_id"]
    )
  }

  func processed(updateId: Int64) throws -> Bool {
    try count("processed_updates", predicate: "update_id = ?", arguments: [updateId]) == 1
  }

  func absenceProjection() throws -> AbsenceProjection {
    let processedUpdates = try env.queue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT update_id, claimed_at FROM processed_updates ORDER BY update_id"
      )
      return try rows.map { row in
        guard
          let updateId = SQLiteStoredValue.int64(in: row, column: "update_id"),
          let claimedAt: Date = row["claimed_at"]
        else {
          throw StoreError.unexpected("fixture processed update is unreadable")
        }
        return ProcessedUpdateProjection(updateId: updateId, claimedAt: claimedAt)
      }
    }
    return AbsenceProjection(
      processedUpdates: processedUpdates,
      learningStateCount: try learningStateCount(),
      lessonSetCount: try lessonSetCount(),
      resetDecisionCount: try resetDecisionCount(),
      resetAuditCount: try resetAuditCount()
    )
  }

  func durableProjection() throws -> DurableProjection {
    let tableNames = [
      "processed_updates",
      "scheduled_jobs",
      "job_learning_state",
      "lesson_sets",
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
      "learning_decisions",
      "audit_events",
    ]
    return try env.queue.read { db in
      let tables = try tableNames.map { tableName in
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))").map { row in
          row["name"] as String
        }
        let rows = try Row.fetchAll(
          db,
          sql: "SELECT * FROM \(tableName) ORDER BY rowid"
        ).map { row in
          columns.map { column in
            row[column] as DatabaseValue
          }
        }
        return DurableTableProjection(name: tableName, columns: columns, rows: rows)
      }
      return DurableProjection(tables: tables)
    }
  }

  func resetDecisionCount() throws -> Int {
    try count(
      "learning_decisions",
      predicate: "kind = ?",
      arguments: [ResetReceipt.kind]
    )
  }

  func resetAuditCount() throws -> Int {
    try count(
      "audit_events",
      predicate: "action = ?",
      arguments: [AuditAction.learningReset.rawValue]
    )
  }

  func learningStateCount() throws -> Int {
    try count("job_learning_state", predicate: "1", arguments: [])
  }

  func lessonSetCount() throws -> Int {
    try count("lesson_sets", predicate: "1", arguments: [])
  }

  func consumptionEpochs(
    table: String,
    id: String,
    predicate: String,
    arguments: StatementArguments
  ) throws -> [Int64] {
    try env.queue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT consumed_at FROM \(table) WHERE \(predicate) ORDER BY \(id)",
        arguments: arguments
      )
      return try rows.map { row in
        guard let epoch = SQLiteStoredValue.int64(in: row, column: "consumed_at") else {
          throw StoreError.unexpected("fixture consumption time is unreadable")
        }
        return epoch
      }
    }
  }

  func count(
    _ table: String,
    predicate: String,
    arguments: StatementArguments
  ) throws -> Int {
    try env.queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM \(table) WHERE \(predicate)",
        arguments: arguments
      ) ?? -1
    }
  }
}
