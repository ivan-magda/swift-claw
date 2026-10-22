import GRDB
import Testing

@testable import ClawData

@Suite
struct PersistenceSchemaMigrationTests {
  @Test
  func migrationV3AddsLaneLifecycleColumns() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    let sessionColumns = try queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(sessions)")
    }
    let runColumns = try queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(runs)")
    }

    let windowColumn = try #require(
      sessionColumns.first { row in
        let name: String = row["name"]
        return name == "window_start_message_id"
      }
    )
    let windowNotNull: Int = windowColumn["notnull"]
    let windowDefault: String = windowColumn["dflt_value"]
    #expect(windowNotNull == 1)
    #expect(windowDefault == "0")

    let triggerColumn = try #require(
      runColumns.first { row in
        let name: String = row["name"]
        return name == "trigger_message_id"
      }
    )
    let triggerNotNull: Int = triggerColumn["notnull"]
    #expect(triggerNotNull == 0)
  }
}
