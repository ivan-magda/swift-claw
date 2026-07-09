import ClawCore
import ClawData
import Foundation
import GRDB

// Shared approval-fabric acceptance helpers (Tasks 21–25). Assertions read raw rows on a FRESH
// pool — the SC3 `AuditRow` idiom — so they bind to the durable schema, not to store internals.
// The `callback_query` update fixture lives in `ApprovalCallbackHandlerTests.swift`
// (`callbackUpdate`), already visible target-wide.

/// One `approvals` row projected for acceptance assertions.
struct ApprovalRowSnapshot: Sendable, Equatable {
  let id: Int64
  let runId: Int64
  let state: String
  let tool: String
  let canonicalTarget: String
  let nonce: String
  let reason: String
}

func fetchApprovals(databasePath: String) throws -> [ApprovalRowSnapshot] {
  let pool = try ClawDatabase.makePool(path: databasePath)
  return try pool.read { db in
    try Row.fetchAll(
      db,
      sql: """
        SELECT id, run_id, state, tool, canonical_target, nonce, reason
        FROM approvals ORDER BY id
        """
    ).map { row in
      ApprovalRowSnapshot(
        id: row["id"],
        runId: row["run_id"],
        state: row["state"],
        tool: row["tool"],
        canonicalTarget: row["canonical_target"],
        nonce: row["nonce"],
        reason: row["reason"]
      )
    }
  }
}

func runState(databasePath: String, runId: Int64) throws -> String? {
  let pool = try ClawDatabase.makePool(path: databasePath)
  return try pool.read { db in
    try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
  }
}

/// Direct column tamper for the Task 25 matrix (args-hash / policy_version / expires_ts).
func tamperApproval(
  databasePath: String,
  id: Int64,
  column: String,
  value: (any DatabaseValueConvertible)?
) throws {
  let pool = try ClawDatabase.makePool(path: databasePath)
  try pool.write { db in
    try db.execute(sql: "UPDATE approvals SET \(column) = ? WHERE id = ?", arguments: [value, id])
  }
}

func sessionFlags(
  databasePath: String,
  sessionId: Int64
) throws -> (tainted: Bool, hasPrivateData: Bool) {
  let pool = try ClawDatabase.makePool(path: databasePath)
  return try pool.read { db in
    let row = try Row.fetchOne(
      db,
      sql: "SELECT tainted, has_private_data FROM sessions WHERE id = ?",
      arguments: [sessionId]
    )
    return (tainted: row?["tainted"] ?? false, hasPrivateData: row?["has_private_data"] ?? false)
  }
}
