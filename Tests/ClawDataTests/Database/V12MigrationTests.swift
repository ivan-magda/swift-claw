import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V12MigrationTests {
  @Test func upgradePreservesLegacyRowsWithoutInventingIdentity() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrator.migrate(queue, upTo: "v11")
    let ids = try queue.write { db in
      try db.execute(
        sql: "INSERT INTO sessions(session_key, created_ts, updated_ts) VALUES (?, ?, ?)",
        arguments: [SessionKey.telegramDM(chatId: 42), Date(), Date()]
      )
      let sessionId = db.lastInsertedRowID
      try db.execute(
        sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (?, ?, ?, ?)",
        arguments: [sessionId, RunState.awaitingApproval.rawValue, Date(), Date()]
      )
      let runId = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO audit_events(ts, actor, action, args_redacted, result_size, decision,
            run_id, session_id)
          VALUES (?, ?, ?, '', 0, ?, ?, ?)
          """,
        arguments: [
          Date(), AuditActor.owner.rawValue, AuditAction.approvalGranted.rawValue,
          "ok", runId, sessionId,
        ]
      )
      return (runId, db.lastInsertedRowID)
    }

    // when
    try ClawDatabase.migrate(queue)

    // then
    try queue.read { db in
      let run = try #require(
        try Row.fetchOne(db, sql: "SELECT * FROM runs WHERE id = ?", arguments: [ids.0])
      )
      #expect(run["state"] == RunState.awaitingApproval.rawValue)
      #expect((run["requester_user_id"] as Int64?) == nil)
      let audit = try #require(
        try Row.fetchOne(db, sql: "SELECT * FROM audit_events WHERE id = ?", arguments: [ids.1])
      )
      #expect(audit["actor"] == AuditActor.owner.rawValue)
      #expect(audit["action"] == AuditAction.approvalGranted.rawValue)
      #expect((audit["actor_user_id"] as Int64?) == nil)
    }
  }
}
