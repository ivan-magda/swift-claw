import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct V17MigrationTests {
  @Test
  func legacyRowsStayIneligible() throws {
    // given
    let root = try makeTemporaryRoot(prefix: "journal-v16")
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let pool = try ClawDatabase.makePool(path: root.appendingPathComponent("claw.sqlite").path)
    try ClawDatabase.migrator.migrate(pool, upTo: "v16")
    try pool.write { db in
      try db.execute(
        sql: "INSERT INTO sessions(id, session_key, created_ts, updated_ts) "
          + "VALUES (1, 'legacy', ?, ?)",
        arguments: [Date(), Date()]
      )
      try db.execute(
        sql: "INSERT INTO runs(id, session_id, state, created_ts, updated_ts) "
          + "VALUES (1, 1, ?, ?, ?)",
        arguments: [RunState.done.rawValue, Date(), Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO approvals(id, run_id, session_id, state, tool, canonical_args,
            canonical_target, args_hash, policy_version, owner_user_id, nonce,
            observation_message_id, tool_call_id, reason, created_ts, expires_ts)
          VALUES (1, 1, 1, 'pending', 'coder', '{}', '', '', '', 42, 'legacy', 1, 't', '', 0, 1)
          """
      )
      try db.execute(
        sql: """
          INSERT INTO coder_jobs(id, origin_run_id, origin_session_id, requester_user_id,
            chat_id, tool_call_id, approval_id, prepared_json, state, slot_reserved,
            process_ownership, created_ts, updated_ts)
          VALUES ('legacy', 1, 1, 42, 42, 't', 1, '{}', 'succeeded', 0, 'none', 0, 1)
          """
      )
    }

    // when
    try ClawDatabase.migrate(pool)

    // then
    let legacyQueue = try JournalStoreGRDB(writer: pool).pendingSources(
      ownerUserID: 42,
      now: Date()
    )
    #expect(legacyQueue.isEmpty)
    try pool.read { db in
      let run = try #require(try Row.fetchOne(db, sql: "SELECT * FROM runs WHERE id = 1"))
      #expect((run["journal_admission"] as Data?) == nil)
      #expect(run["state"] == RunState.done.rawValue)
      let job = try #require(
        try Row.fetchOne(db, sql: "SELECT * FROM coder_jobs WHERE id = 'legacy'")
      )
      #expect((job["journal_scope"] as Data?) == nil)
    }
  }
}
