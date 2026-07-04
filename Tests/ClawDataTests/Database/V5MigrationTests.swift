import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V5MigrationTests {
  @Test func vFiveAddsNullableToolColumns() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    let columns = try queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(messages)").map { row in row["name"] as String }
    }
    #expect(columns.contains("tool_calls"))
    #expect(columns.contains("tool_call_id"))
  }

  @Test func vFiveUpgradesAPopulatedVFourDatabase() throws {
    // given — a v4 database that already holds a message row
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrator.migrate(queue, upTo: "v4")
    try queue.write { db in
      try db.execute(
        sql:
          "INSERT INTO sessions(session_key, created_ts, updated_ts, tainted) VALUES ('tg:dm:1', ?, ?, 0)",
        arguments: [Date(), Date()]
      )
      try db.execute(
        sql:
          "INSERT INTO messages(session_id, role, content, provenance, ts) VALUES (1, 'user', 'old row', 'trusted', ?)",
        arguments: [Date()]
      )
    }

    // when
    try ClawDatabase.migrate(queue)

    // then — the old row survives with NULL tool columns
    let row = try queue.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT content, tool_calls, tool_call_id FROM messages WHERE id = 1"
      )
    }
    #expect(row?["content"] == "old row")
    #expect((row?["tool_calls"] as String?) == nil)
    #expect((row?["tool_call_id"] as String?) == nil)
  }

  /// §20 item 5 — BLOCKING verification: GRDB's generated external-content sync triggers must
  /// stay consistent when a non-indexed column is updated, and delete must still de-index.
  @Test func ftsSurvivesToolColumnWritesAndDeletes() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try queue.write { db in
      try db.execute(
        sql:
          "INSERT INTO sessions(session_key, created_ts, updated_ts, tainted) VALUES ('tg:dm:1', ?, ?, 0)",
        arguments: [Date(), Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts, tool_calls)
          VALUES (1, 'assistant', 'fetch the zebra page', 'trusted', ?, '[]')
          """,
        arguments: [Date()]
      )
    }
    func zebraMatches() throws -> Int {
      try queue.read { db in
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'zebra'"
        ) ?? -1
      }
    }
    #expect(try zebraMatches() == 1)

    // when — update ONLY the non-indexed column
    try queue.write { db in
      try db.execute(
        sql: "UPDATE messages SET tool_calls = ? WHERE id = 1",
        arguments: ["[{\"id\":\"c\",\"name\":\"n\",\"arguments\":\"{}\"}]"]
      )
    }

    // then — still exactly one match (no duplicate, no loss)
    #expect(try zebraMatches() == 1)

    // when — delete the row
    try queue.write { db in
      try db.execute(sql: "DELETE FROM messages WHERE id = 1")
    }

    // then — de-indexed
    #expect(try zebraMatches() == 0)
  }
}
