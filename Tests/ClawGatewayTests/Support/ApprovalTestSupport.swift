import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

// Shared approval-fabric acceptance helpers (Tasks 21–25). Assertions read raw rows on a
// SEPARATE pool (one cached per database path) — the SC3 `AuditRow` idiom — so they bind to the
// durable schema, not to store internals.
// The `callback_query` update fixture lives in `ApprovalCallbackHandlerTests.swift`
// (`callbackUpdate`), already visible target-wide.

/// Suspends a real `file_write` proposal to a PENDING approval and returns the harness + row —
/// the shared fixture of the Task 25 acceptance suites (matrix + done-when).
func suspendFileWrite() async throws -> (SC3Harness, ApprovalRowSnapshot) {
  // given
  let harness = try makeSC3Harness(
    scripts: [
      [
        toolCallResponse([
          ToolCall(
            id: "w1",
            name: "file_write",
            argumentsJSON: #"{"path":"notes/plan.md","content":"hello fabric","overwrite":false}"#
          )
        ]),
        okResponse(content: "Saved the plan."),
      ]
    ],
    httpResponses: [:]
  )
  _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write the plan"))
  let approval = try #require(
    await pollUntil {
      try fetchApprovals(databasePath: harness.databasePath).first
    }
  )
  #expect(approval.state == ApprovalState.pending.rawValue)
  return (harness, approval)
}

/// The owner-side Approve callback payload for a parked approval's nonce.
func approveData(_ nonce: String) -> String {
  ApprovalKeyboard.callbackData(nonce: nonce, verdict: ApprovalKeyboard.Verdict.approve)
}

/// One pool per database path: these helpers run inside 10 ms poll loops, and a fresh
/// `DatabasePool` per tick churns connections and WAL file handles for no isolation benefit —
/// the raw-row reads only need a connection onto the same on-disk database.
private final class SnapshotPoolCache: @unchecked Sendable {
  static let shared = SnapshotPoolCache()

  private let lock = NSLock()
  private var pools: [String: DatabasePool] = [:]

  func pool(at path: String) throws -> DatabasePool {
    lock.lock()
    defer { lock.unlock() }
    if let cached = pools[path] {
      return cached
    }
    let created = try ClawDatabase.makePool(path: path)
    pools[path] = created
    return created
  }
}

/// One `approvals` row projected for acceptance assertions.
struct ApprovalRowSnapshot: Sendable, Equatable {
  let id: Int64
  let runId: Int64
  let state: String
  let tool: String
  let canonicalTarget: String
  let canonicalArgsJSON: String
  let nonce: String
  let reason: String
}

func fetchApprovals(databasePath: String) throws -> [ApprovalRowSnapshot] {
  let pool = try SnapshotPoolCache.shared.pool(at: databasePath)
  return try pool.read { db in
    try Row.fetchAll(
      db,
      sql: """
        SELECT id, run_id, state, tool, canonical_target, canonical_args, nonce, reason
        FROM approvals ORDER BY id
        """
    ).map { row in
      ApprovalRowSnapshot(
        id: row["id"],
        runId: row["run_id"],
        state: row["state"],
        tool: row["tool"],
        canonicalTarget: row["canonical_target"],
        canonicalArgsJSON: row["canonical_args"],
        nonce: row["nonce"],
        reason: row["reason"]
      )
    }
  }
}

func runState(databasePath: String, runId: Int64) throws -> String? {
  let pool = try SnapshotPoolCache.shared.pool(at: databasePath)
  return try pool.read { db in
    try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
  }
}

/// Every run row's state, oldest first — the FIFO queue behind the parked lane in durable form.
func runStates(databasePath: String) throws -> [String] {
  let pool = try SnapshotPoolCache.shared.pool(at: databasePath)
  return try pool.read { db in
    try String.fetchAll(db, sql: "SELECT state FROM runs ORDER BY id")
  }
}

/// Direct column tamper for the Task 25 matrix (args-hash / policy_version / expires_ts).
func tamperApproval(
  databasePath: String,
  id: Int64,
  column: String,
  value: (any DatabaseValueConvertible)?
) throws {
  let pool = try SnapshotPoolCache.shared.pool(at: databasePath)
  try pool.write { db in
    try db.execute(sql: "UPDATE approvals SET \(column) = ? WHERE id = ?", arguments: [value, id])
  }
}

func sessionFlags(
  databasePath: String,
  sessionId: Int64
) throws -> (tainted: Bool, hasPrivateData: Bool) {
  let pool = try SnapshotPoolCache.shared.pool(at: databasePath)
  return try pool.read { db in
    let row = try Row.fetchOne(
      db,
      sql: "SELECT tainted, has_private_data FROM sessions WHERE id = ?",
      arguments: [sessionId]
    )
    return (tainted: row?["tainted"] ?? false, hasPrivateData: row?["has_private_data"] ?? false)
  }
}
