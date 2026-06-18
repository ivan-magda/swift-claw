import GRDB
import Testing

@testable import ClawData

@Suite struct ClawDatabaseTests {
  @Test func migrationCreatesExpectedTables() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    let tables = try queue.read { db -> Set<String> in
      let names = try String.fetchAll(
        db,
        sql:
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'"
      )
      return Set(names)
    }
    #expect(tables.isSuperset(of: ["allowlist", "processed_updates", "update_cursor"]))
  }

  @Test func foreignKeysAndBusyTimeoutAreSet() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // then
    try queue.read { db in
      let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
      #expect(foreignKeys == 1)
      let busyTimeout = try Int.fetchOne(db, sql: "PRAGMA busy_timeout")
      #expect((busyTimeout ?? 0) >= 5000)
    }
  }

  @Test func migrationIsIdempotent() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    try ClawDatabase.migrate(queue)
  }
}
