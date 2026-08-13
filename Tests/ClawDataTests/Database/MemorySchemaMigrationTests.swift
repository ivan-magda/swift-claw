import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct MemorySchemaMigrationTests {
  private func migratedQueue() throws -> DatabaseQueue {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return queue
  }

  @Test func v4CreatesMemoryItemsWithExpectedColumns() throws {
    // given
    let queue = try migratedQueue()

    // when
    let columns = try queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(memory_items)")
    }

    // then
    let names = Set(columns.map { row in row["name"] as String })
    #expect(
      names.isSuperset(of: [
        "id", "text", "kind", "sensitivity", "importance", "source", "session_id", "created_at",
      ])
    )
    let importanceColumn = try #require(
      columns.first { row in (row["name"] as String) == "importance" }
    )
    #expect((importanceColumn["type"] as String).uppercased().contains("INT"))
    let textColumn = try #require(columns.first { row in (row["name"] as String) == "text" })
    #expect((textColumn["notnull"] as Int) == 1)
  }

  @Test func v4CreatesCreatedAtAndKindIndexes() throws {
    // given
    let queue = try migratedQueue()

    // when
    let indexNames = try queue.read { db in
      Set(
        try String.fetchAll(
          db,
          sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='memory_items'"
        )
      )
    }

    // then
    #expect(indexNames.contains("index_memory_items_created_at"))
    #expect(indexNames.contains("index_memory_items_kind"))
  }

  @Test func deletingASessionNullsMemoryItemProvenance() throws {
    // given - ON DELETE SET NULL keeps an owner fact after its learned-in session is gone.
    let queue = try migratedQueue()
    let createdAt = Date(timeIntervalSince1970: 1_000)
    try queue.write { db in
      try db.execute(
        sql:
          "INSERT INTO sessions(session_key, created_ts, updated_ts, tainted) VALUES ('k', ?, ?, 0)",
        arguments: [createdAt, createdAt]
      )
      try db.execute(
        sql: """
          INSERT INTO memory_items(text, kind, sensitivity, importance, source, session_id, created_at)
          VALUES ('owner fact', 'user', 'normal', 1, 'owner', 1, ?)
          """,
        arguments: [createdAt]
      )
    }

    // when
    try queue.write { db in
      try db.execute(sql: "DELETE FROM sessions WHERE id = 1")
    }

    // then
    let sessionId = try queue.read { db in
      try Int64.fetchOne(db, sql: "SELECT session_id FROM memory_items WHERE id = 1")
    }
    let survivingText = try queue.read { db in
      try String.fetchOne(db, sql: "SELECT text FROM memory_items WHERE id = 1")
    }
    #expect(sessionId == nil)
    #expect(survivingText == "owner fact")
  }
}
