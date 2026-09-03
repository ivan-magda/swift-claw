import ClawCore
import Foundation
import GRDB

// MARK: - Verdicts

extension ScheduledLearningStoreGRDB {
  public func evaluation(runId: Int64) throws(StoreError) -> LearningEvaluation? {
    try database.readMapping { db in
      try Self.readEvaluation(db, runId: runId)
    }
  }
}

// MARK: - Result-Commit Write

extension ScheduledLearningStoreGRDB {
  /// One verdict, plus the evaluator half of the surface it was reached on. Reachable only from the
  /// result commit: the row and the operation that paid for it have to become durable together, or
  /// a crash between them leaves evidence marked judged that nothing may ever judge.
  static func recordEvaluation(
    _ db: Database,
    operation: OperationRow,
    evaluation: LearningEvaluation,
    now: Date
  ) throws {
    let runId = try evaluatedRunId(db, operation: operation)
    guard let compatibility = try readCompatibility(db, runId: runId) else {
      throw StoreError.unexpected(
        "run \(runId) was evaluated with no frozen compatibility surface to file it under"
      )
    }
    try stampEvaluatorSurface(db, runId: runId, surface: evaluation.evaluator)

    let compatibilityDigest = compatibility.digest(evaluator: evaluation.evaluator)
    let issueCodes = try issueCodesJSON(evaluation.issueCodes)
    try db.execute(
      sql: """
        INSERT INTO learning_evaluations(evaluation_digest, job_id, learning_epoch, run_id,
          evidence_digest, outcome, issue_codes, rubric_version, evaluator_prompt_version,
          evaluator_schema_version, compatibility_digest, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        digest(
          operation: operation,
          runId: runId,
          evaluation: evaluation,
          issueCodes: issueCodes,
          compatibility: compatibilityDigest
        ).rawValue,
        operation.jobId,
        operation.epoch.value,
        runId,
        operation.sourceDigest,
        evaluation.outcome.rawValue,
        issueCodes,
        String(evaluation.evaluator.rubricVersion),
        String(evaluation.evaluator.promptVersion),
        String(evaluation.evaluator.schemaVersion),
        compatibilityDigest.rawValue,
        EpochSecondCodec.epoch(now),
      ]
    )
  }
}

// MARK: - Verdict Rows

private extension ScheduledLearningStoreGRDB {
  /// The evaluator's source digest names a sealed receipt, and a receipt is keyed by its run — so
  /// the run is resolved from the operation's own identity rather than taken from the caller, which
  /// could otherwise file one run's verdict against another.
  static func evaluatedRunId(_ db: Database, operation: OperationRow) throws -> Int64 {
    let runId = try Int64.fetchOne(
      db,
      sql: """
        SELECT run_id FROM learning_evidence
        WHERE job_id = ? AND learning_epoch = ? AND evidence_digest = ?
        """,
      arguments: [operation.jobId, operation.epoch.value, operation.sourceDigest]
    )
    guard let runId else {
      throw StoreError.unexpected(
        "operation \(operation.id.rawValue) has no sealed receipt to file a verdict against"
      )
    }
    return runId
  }

  /// Frozen into every verdict identity. A change to the field list below must change this value
  /// too, so verdicts stored under the old list keep the identity they were written with.
  static let evaluationDigestPrefix = "learning-evaluation/v1"

  static func digest(
    operation: OperationRow,
    runId: Int64,
    evaluation: LearningEvaluation,
    issueCodes: String,
    compatibility: CompatibilityDigest
  ) -> EvaluationDigest {
    let fields = [
      evaluationDigestPrefix,
      String(operation.jobId),
      String(operation.epoch.value),
      String(runId),
      operation.sourceDigest,
      evaluation.outcome.rawValue,
      issueCodes,
      compatibility.rawValue,
    ]
    return EvaluationDigest(rawValue: SHA256Digest.hex(fields.joined(separator: ":")))
  }

  /// Deliberately throwing. A swallowed encode would store a verdict whose codes are unreadable,
  /// and the reducer compares codes by exact equality — an empty list there reads as "no defect
  /// found" rather than as a lost one.
  static func issueCodesJSON(_ codes: [String]) throws -> String {
    let encoded = try JSONEncoder().encode(codes)
    // Lossless, not failable: these are `JSONEncoder` bytes, so a failable conversion here would
    // add a branch that can never be taken.
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: encoded, as: UTF8.self)
  }

  static func readEvaluation(_ db: Database, runId: Int64) throws -> LearningEvaluation? {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT learning_evaluations.outcome, learning_evaluations.issue_codes,
          learning_evaluations.rubric_version, learning_evaluations.evaluator_prompt_version,
          learning_evaluations.evaluator_schema_version, run_compatibility.evaluator_route
        FROM learning_evaluations
        LEFT JOIN run_compatibility ON run_compatibility.run_id = learning_evaluations.run_id
        WHERE learning_evaluations.run_id = ?
        """,
      arguments: [runId]
    )
    guard let row else {
      return nil
    }
    guard
      let outcome = EvaluatorOutcome(rawValue: row["outcome"]),
      let route: String = row["evaluator_route"],
      let promptVersion = Int(row["evaluator_prompt_version"] as String),
      let schemaVersion = Int(row["evaluator_schema_version"] as String),
      let rubricVersion = Int(row["rubric_version"] as String),
      let issueCodes = try? JSONDecoder().decode(
        [String].self,
        from: Data((row["issue_codes"] as String).utf8)
      )
    else {
      throw StoreError.unexpected("run \(runId) holds an unreadable evaluation")
    }
    return LearningEvaluation(
      outcome: outcome,
      issueCodes: issueCodes,
      evaluator: EvaluatorSurface(
        route: route,
        promptVersion: promptVersion,
        schemaVersion: schemaVersion,
        rubricVersion: rubricVersion
      )
    )
  }
}
