import ClawCore
import Foundation
import GRDB

// MARK: - Verdicts

extension ScheduledLearningStoreGRDB {
  struct StoredEvaluationProjection {
    let digest: EvaluationDigest
    let jobId: Int64
    let epoch: LearningEpoch
    let runId: Int64
    let evidenceDigest: EvidenceDigest
    let evaluation: LearningEvaluation
    let issueCodesJSON: String
    let compatibilityDigest: CompatibilityDigest
    let createdAt: Date
  }

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
    guard
      let compatibility = try readCompatibility(db, runId: runId),
      // The binding carries the two inputs the compatibility row does not: what the job asked for
      // when this run fired, and which stable set it was asking under.
      let binding = try readBinding(db, runId: runId)
    else {
      throw StoreError.unexpected(
        "run \(runId) was evaluated with no frozen compatibility surface to file it under"
      )
    }
    try stampEvaluatorSurface(db, runId: runId, surface: evaluation.evaluator)

    let compatibilityDigest = compatibility.digest(
      binding: binding,
      terminalRoute: try readTerminalRoute(db, runId: runId),
      evaluator: evaluation.evaluator
    )
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
    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: .system,
        action: .learningEvaluated,
        decision: evaluation.outcome.rawValue,
        runId: runId,
        ts: now
      )
    )
  }
}

// MARK: - Verdict Rows

extension ScheduledLearningStoreGRDB {
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
    return EvaluationDigest(rawValue: SHA256Digest.hex(CanonicalDigestInput.joined(fields)))
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
    let rows = try storedEvaluations(db, runId: runId)
    guard rows.count <= 1 else {
      throw StoreError.unexpected("run \(runId) holds multiple evaluations")
    }
    return rows.first?.evaluation
  }

  static func storedEvaluations(
    _ db: Database,
    runId: Int64
  ) throws -> [StoredEvaluationProjection] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT learning_evaluations.evaluation_digest, learning_evaluations.job_id,
          learning_evaluations.learning_epoch, learning_evaluations.run_id,
          learning_evaluations.evidence_digest, learning_evaluations.outcome,
          learning_evaluations.issue_codes,
          learning_evaluations.rubric_version, learning_evaluations.evaluator_prompt_version,
          learning_evaluations.evaluator_schema_version,
          learning_evaluations.compatibility_digest, learning_evaluations.created_at,
          run_compatibility.evaluator_route
        FROM learning_evaluations
        LEFT JOIN run_compatibility ON run_compatibility.run_id = learning_evaluations.run_id
        WHERE learning_evaluations.run_id = ?
        ORDER BY learning_evaluations.evaluation_digest
        """,
      arguments: [runId]
    )
    return try rows.map { row in
      try decodeStoredEvaluation(row, expectedRunId: runId)
    }
  }

  static func decodeCanonicalIssueCodes(_ json: String) throws -> [String] {
    guard
      let data = json.data(using: .utf8),
      let codes = try? JSONDecoder().decode([String].self, from: data),
      codes.count <= EvaluatorOutput.maxIssueCodes,
      codes.allSatisfy({ code in
        code.isEmpty == false && code.count <= EvaluatorOutput.maxIssueCodeCharacters
      }),
      Set(codes).count == codes.count,
      codes == codes.sorted(),
      try issueCodesJSON(codes) == json
    else {
      throw StoreError.unexpected("assignment source has noncanonical issue codes")
    }
    return codes
  }

  private static func decodeStoredEvaluation(
    _ row: Row,
    expectedRunId: Int64
  ) throws -> StoredEvaluationProjection {
    guard
      let digestRaw = SQLiteStoredValue.string(in: row, column: "evaluation_digest"),
      isCanonicalDigest(digestRaw),
      let jobId = SQLiteStoredValue.int64(in: row, column: "job_id"),
      jobId > 0,
      let epochRaw = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      epochRaw > 0,
      let runId = SQLiteStoredValue.int64(in: row, column: "run_id"),
      runId == expectedRunId,
      let evidenceRaw = SQLiteStoredValue.string(in: row, column: "evidence_digest"),
      isCanonicalDigest(evidenceRaw),
      let outcomeRaw = SQLiteStoredValue.string(in: row, column: "outcome"),
      let outcome = EvaluatorOutcome(rawValue: outcomeRaw),
      let issueJSON = SQLiteStoredValue.string(in: row, column: "issue_codes"),
      let issueCodes = try? decodeCanonicalIssueCodes(issueJSON),
      let rubricRaw = SQLiteStoredValue.string(in: row, column: "rubric_version"),
      let rubricVersion = Int(rubricRaw),
      let promptRaw = SQLiteStoredValue.string(in: row, column: "evaluator_prompt_version"),
      let promptVersion = Int(promptRaw),
      let schemaRaw = SQLiteStoredValue.string(in: row, column: "evaluator_schema_version"),
      let schemaVersion = Int(schemaRaw),
      let compatibilityRaw = SQLiteStoredValue.string(
        in: row,
        column: "compatibility_digest"
      ),
      isCanonicalDigest(compatibilityRaw),
      let createdRaw = SQLiteStoredValue.int64(in: row, column: "created_at"),
      let createdAt = EpochSecondCodec.date(fromEpoch: createdRaw),
      let route = SQLiteStoredValue.string(in: row, column: "evaluator_route"),
      route.isEmpty == false
    else {
      throw StoreError.unexpected("run \(expectedRunId) holds an unreadable evaluation")
    }
    let evaluation = LearningEvaluation(
      outcome: outcome,
      issueCodes: issueCodes,
      evaluator: EvaluatorSurface(
        route: route,
        promptVersion: promptVersion,
        schemaVersion: schemaVersion,
        rubricVersion: rubricVersion
      )
    )
    guard evaluation.issueCodes == issueCodes else {
      throw StoreError.unexpected("run \(expectedRunId) holds noncanonical evaluation codes")
    }
    return StoredEvaluationProjection(
      digest: EvaluationDigest(rawValue: digestRaw),
      jobId: jobId,
      epoch: LearningEpoch(epochRaw),
      runId: runId,
      evidenceDigest: EvidenceDigest(rawValue: evidenceRaw),
      evaluation: evaluation,
      issueCodesJSON: issueJSON,
      compatibilityDigest: CompatibilityDigest(rawValue: compatibilityRaw),
      createdAt: createdAt
    )
  }
}
