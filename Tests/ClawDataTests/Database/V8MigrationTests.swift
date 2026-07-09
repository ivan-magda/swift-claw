import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V8MigrationTests {
  private func columnNames(_ queue: DatabaseQueue, table: String) throws -> [String] {
    try queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
        row["name"] as String
      }
    }
  }

  /// Seeds one session + one run via raw SQL so approvals rows have valid FK targets.
  private func seedSessionAndRun(_ queue: DatabaseQueue, state: String = "RUNNING") throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES ('tg:dm:7', ?, ?, 0)
          """,
        arguments: [Date(), Date()]
      )
      try db.execute(
        sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (1, ?, ?, ?)",
        arguments: [state, Date(), Date()]
      )
    }
  }

  private func insertApproval(
    _ db: Database,
    runId: Int64,
    nonce: String,
    state: String = "PENDING"
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO approvals(run_id, session_id, state, tool, canonical_args, canonical_target,
          args_hash, policy_version, owner_user_id, nonce, observation_message_id, tool_call_id,
          reason, created_ts, expires_ts)
        VALUES (?, 1, ?, 'file_write', '{}', '/w/plan.md', 'h16', 'pv16', 7, ?, 1, 'c1',
          'ask_tier', 1782000000, 1782003600)
        """,
      arguments: [runId, state, nonce]
    )
  }

  @Test func vEightCreatesTheApprovalsTableAndLinkageColumns() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then — the required spec §4.1 columns (superset; order and extras not pinned)
    let approvalColumns = Set(try columnNames(queue, table: "approvals"))
    #expect(
      approvalColumns.isSuperset(of: [
        "id", "run_id", "session_id", "state", "tool", "canonical_args", "canonical_target",
        "args_hash", "policy_version", "owner_user_id", "nonce", "observation_message_id",
        "tool_call_id", "reason", "prompt_message_id", "created_ts", "expires_ts", "resolved_ts",
      ])
    )
    #expect(try columnNames(queue, table: "runs").contains("policy_version"))
    #expect(try columnNames(queue, table: "sessions").contains("has_private_data"))
    let outboundColumns = Set(try columnNames(queue, table: "outbound_deliveries"))
    #expect(outboundColumns.isSuperset(of: ["approval_id", "reply_markup"]))
  }

  @Test func pendingPerRunIndexIsUniqueAndPartial() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then — UNIQUE + WHERE in sqlite_master (the V6 partial-index idiom)
    let indexSQL = try queue.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT sql FROM sqlite_master
          WHERE type = 'index' AND name = 'index_approvals_pending_run'
          """
      )
    }
    #expect(indexSQL?.localizedCaseInsensitiveContains("unique") == true)
    #expect(indexSQL?.localizedCaseInsensitiveContains("where") == true)
    #expect(indexSQL?.contains("run_id") == true)
  }

  @Test func atMostOneLivePendingApprovalPerRun() throws {
    // given — one run already holding a PENDING approval
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try seedSessionAndRun(queue)
    try queue.write { db in
      try self.insertApproval(db, runId: 1, nonce: "nonce-a")
    }

    // when / then — a second PENDING row for the same run violates the partial UNIQUE index
    #expect(throws: (any Error).self) {
      try queue.write { db in
        try self.insertApproval(db, runId: 1, nonce: "nonce-b")
      }
    }

    // and a RESOLVED row does not block a fresh PENDING one (the index is partial)
    try queue.write { db in
      try db.execute(sql: "UPDATE approvals SET state = 'REJECTED' WHERE nonce = 'nonce-a'")
      try self.insertApproval(db, runId: 1, nonce: "nonce-c")
    }
    let pendingCount = try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM approvals WHERE state = 'PENDING'")
    }
    #expect(pendingCount == 1)
  }

  @Test func nonceIsGloballyUnique() throws {
    // given — a resolved row already holds the nonce (single-use = never reused, spec §6.2)
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try seedSessionAndRun(queue)
    try queue.write { db in
      try self.insertApproval(db, runId: 1, nonce: "nonce-a", state: "REJECTED")
    }

    // when / then
    #expect(throws: (any Error).self) {
      try queue.write { db in
        try self.insertApproval(db, runId: 1, nonce: "nonce-a")
      }
    }
  }

  @Test func vEightUpgradesAPopulatedVSevenDatabase() throws {
    // given — a v7 database holding a session, a run, and a PENDING outbox row
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrator.migrate(queue, upTo: "v7")
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES ('tg:dm:1', ?, ?, 0)
          """,
        arguments: [Date(), Date()]
      )
      try db.execute(
        sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (1, 'DONE', ?, ?)",
        arguments: [Date(), Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
            payload_hash, status, created_ts)
          VALUES (1, 0, 7, '1:0', 'hello', 'h', 'PENDING', ?)
          """,
        arguments: [Date()]
      )
    }

    // when
    try ClawDatabase.migrate(queue)

    // then — additive nullable columns: the old rows stay valid with NULL/default backfill
    let sessionFlag = try queue.read { db in
      try Bool.fetchOne(db, sql: "SELECT has_private_data FROM sessions WHERE id = 1")
    }
    #expect(sessionFlag == false)
    let runPolicy = try queue.read { db in
      try String.fetchOne(db, sql: "SELECT policy_version FROM runs WHERE id = 1")
    }
    #expect(runPolicy == nil)
    let outboundRow = try queue.read { db in
      try Row.fetchOne(
        db,
        sql:
          "SELECT status, approval_id, reply_markup FROM outbound_deliveries WHERE dedup_key = '1:0'"
      )
    }
    #expect(outboundRow?["status"] == "PENDING")
    #expect((outboundRow?["approval_id"] as Int64?) == nil)
    #expect((outboundRow?["reply_markup"] as String?) == nil)
  }
}
