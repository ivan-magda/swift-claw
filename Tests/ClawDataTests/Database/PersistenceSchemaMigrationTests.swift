import Foundation  // Date — GRDB does not re-export Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct PersistenceSchemaMigrationTests {
  @Test func createsPersistenceTables() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    let tables = try queue.read { db in
      Set(
        try String.fetchAll(
          db,
          sql:
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'"
        )
      )
    }
    #expect(
      tables.isSuperset(of: [
        "sessions", "messages", "runs", "provider_usage", "outbound_deliveries", "audit_events",
      ])
    )
  }

  @Test func foreignKeysAreEnforced() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)

    // then — a message referencing a missing session violates the FK
    #expect {
      try queue.write { db in
        try db.execute(
          sql:
            "INSERT INTO messages(session_id, role, content, provenance, ts) VALUES (9999,'user','x','trusted',?)",
          arguments: [Date()]
        )
      }
    } throws: { error in
      guard let dbErr = error as? DatabaseError else { return false }
      return dbErr.resultCode.primaryResultCode == .SQLITE_CONSTRAINT
        && (dbErr.message?.contains("FOREIGN KEY") ?? false)
    }
  }

  @Test func migrationV3AddsLaneLifecycleColumns() throws {
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
