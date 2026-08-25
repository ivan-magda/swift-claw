import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V10MigrationTests {
  private static let seededAt = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Legacy Upgrade

  @Test func vTenAddsTheTelegramAddressingColumnsWithoutTouchingExistingRows() throws {
    // given — a populated v9 database, i.e. rows written before the columns existed
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVNine(queue)
    let legacyRun = try queue.read { db in
      let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM runs"))
      return (
        id: row["id"] as Int64,
        triggerMessageId: row["trigger_message_id"] as Int64
      )
    }

    // when
    try ClawDatabase.migrate(queue)

    // then — the run survives with a null Telegram trigger id
    let runs = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM runs ORDER BY id")
    }
    #expect(runs.count == 1)
    #expect(runs[0]["id"] == legacyRun.id)
    #expect(runs[0]["state"] == "DONE")
    #expect(runs[0]["trigger_message_id"] == legacyRun.triggerMessageId)
    #expect((runs[0]["trigger_telegram_message_id"] as Int64?) == nil)

    // and the delivery survives with null topic and reply-target columns
    let deliveries = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM outbound_deliveries ORDER BY step_index")
    }
    #expect(deliveries.count == 1)
    #expect(deliveries[0]["chat_id"] == 7)
    #expect(deliveries[0]["payload"] == "already delivered")
    #expect((deliveries[0]["message_thread_id"] as Int64?) == nil)
    #expect((deliveries[0]["reply_to_message_id"] as Int64?) == nil)
  }
}

// MARK: - Legacy Fixtures

private extension V10MigrationTests {
  /// A v9 database holding the two rows v10 alters: a run and an outbound delivery.
  static func seedVNine(_ queue: DatabaseQueue) throws {
    try ClawDatabase.migrator.migrate(queue, upTo: "v9")
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES ('tg:dm:7', ?, ?, 0)
          """,
        arguments: [seededAt, seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts)
          VALUES (1, NULL, 'user', 'find the plan', 'trusted', ?)
          """,
        arguments: [seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_message_id)
          VALUES (1, 'DONE', ?, ?, 1)
          """,
        arguments: [seededAt, seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
            payload_hash, status, created_ts)
          VALUES (1, 0, 7, 'dedup-1', 'already delivered', 'hash-1', 'SENT', ?)
          """,
        arguments: [seededAt]
      )
    }
  }
}
