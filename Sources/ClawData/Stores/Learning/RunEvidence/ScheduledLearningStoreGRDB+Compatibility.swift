import ClawCore
import Foundation
import GRDB

// MARK: - Compatibility Snapshot

extension ScheduledLearningStoreGRDB {
  public func freezeCompatibility(runId: Int64, surface: RunSurface) throws(StoreError) {
    try database.writeMapping { db in
      // OR IGNORE, and the values come from the caller's own pickup rather than from a later read:
      // the first snapshot is the one the run executed against, and a resume or a retry must never
      // move it. The join is what keeps an unbound run — a heartbeat, an inbound turn, a fire under
      // a disarmed daemon — out of the table entirely.
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO run_compatibility(run_id, job_id, learning_epoch,
            context_schema_version, tool_catalog_digest, policy_version, skill_set_digest,
            configured_route)
          SELECT run_id, job_id, learning_epoch, ?, ?, ?, ?, ?
          FROM run_learning_bindings WHERE run_id = ?
          """,
        arguments: [
          surface.contextSchemaVersion,
          surface.toolCatalogDigest,
          surface.policyVersion,
          surface.skillSetDigest,
          surface.configuredRoute,
          runId,
        ]
      )
    }
  }

  public func compatibility(runId: Int64) throws(StoreError) -> RunCompatibility? {
    try database.readMapping { db in
      try Self.readCompatibility(db, runId: runId)
    }
  }
}

// MARK: - Rows

extension ScheduledLearningStoreGRDB {
  /// Returns nil when the row is absent or any frozen column is missing. A partially written
  /// surface is not a surface: the sealer files a run under what it ran on or under nothing.
  static func readCompatibility(_ db: Database, runId: Int64) throws -> RunCompatibility? {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT job_id, learning_epoch, context_schema_version, tool_catalog_digest, policy_version,
          skill_set_digest, configured_route, evidence_schema_version, classifier_version
        FROM run_compatibility WHERE run_id = ?
        """,
      arguments: [runId]
    )
    guard
      let row,
      let contextSchemaVersion: String = row["context_schema_version"],
      let toolCatalogDigest: String = row["tool_catalog_digest"],
      let policyVersion: String = row["policy_version"],
      let skillSetDigest: String = row["skill_set_digest"],
      let configuredRoute: String = row["configured_route"]
    else {
      return nil
    }
    return RunCompatibility(
      runId: runId,
      jobId: row["job_id"],
      epoch: LearningEpoch(row["learning_epoch"]),
      contextSchemaVersion: contextSchemaVersion,
      toolCatalogDigest: toolCatalogDigest,
      policyVersion: policyVersion,
      skillSetDigest: skillSetDigest,
      configuredRoute: configuredRoute,
      evidenceSchemaVersion: row["evidence_schema_version"],
      classifierVersion: row["classifier_version"]
    )
  }

  /// The evaluator's own route and versions, stamped by the transaction that commits its verdict
  /// so a verdict and the surface it was reached on can never disagree. The pickup-time columns
  /// beside them are left alone: `configured_route` describes the run being judged, not the call
  /// judging it.
  static func stampEvaluatorSurface(
    _ db: Database,
    runId: Int64,
    surface: EvaluatorSurface
  ) throws {
    try db.execute(
      sql: """
        UPDATE run_compatibility
        SET evaluator_route = ?, evaluator_prompt_version = ?, evaluator_schema_version = ?,
          rubric_version = ?
        WHERE run_id = ?
        """,
      arguments: [
        surface.route,
        String(surface.promptVersion),
        String(surface.schemaVersion),
        String(surface.rubricVersion),
        runId,
      ]
    )
  }

  /// The two versions the sealer itself applied, stamped in the sealing transaction so a receipt
  /// and the compatibility row that describes it can never disagree about which rules produced it.
  static func stampSealingVersions(_ db: Database, runId: Int64) throws {
    try db.execute(
      sql: """
        UPDATE run_compatibility SET evidence_schema_version = ?, classifier_version = ?
        WHERE run_id = ?
        """,
      arguments: [EvidenceLimits.schemaVersion, EligibilityClassifier.version, runId]
    )
  }
}
