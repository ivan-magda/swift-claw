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
    #expect(throws: (any Error).self) {
      try queue.write { db in
        try db.execute(
          sql:
            "INSERT INTO messages(session_id, role, content, provenance, ts) VALUES (9999,'user','x','trusted',?)",
          arguments: [Date()]
        )
      }
    }
  }
}
