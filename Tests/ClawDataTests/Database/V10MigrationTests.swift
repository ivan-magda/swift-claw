import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V10MigrationTests {
  private static let seededAt = Date(timeIntervalSince1970: 1_700_000_000)

  private func columnNames(_ queue: DatabaseQueue, table: String) throws -> [String] {
    try queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
        row["name"] as String
      }
    }
  }

  /// A v9 database holding one live run and one already-finished run.
  private func seedVNine(_ queue: DatabaseQueue) throws {
    try ClawDatabase.migrator.migrate(queue, upTo: "v9")
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES ('tg:dm:7', ?, ?, 0)
          """,
        arguments: [Self.seededAt, Self.seededAt]
      )
      for state in ["RUNNING", "DONE"] {
        try db.execute(
          sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (1, ?, ?, ?)",
          arguments: [state, Self.seededAt, Self.seededAt]
        )
      }
    }
  }

  @Test func vTenAddsTheAutoApproveWindowColumnToRuns() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    #expect(try columnNames(queue, table: "runs").contains("auto_approve_window"))
  }

  @Test func everyPreUpgradeRunReadsAsAClosedWindow() throws {
    // given — runs written before the column existed
    let queue = try ClawDatabase.makeInMemoryQueue()
    try seedVNine(queue)

    // when
    try ClawDatabase.migrate(queue)

    // then — the NOT NULL default backfills them closed, live run included
    let store = RunStoreGRDB(writer: queue)
    #expect(try store.isAutoApproveWindowOpen(runId: 1) == false)
    #expect(try store.isAutoApproveWindowOpen(runId: 2) == false)
    let backfilled = try queue.read { db in
      try Bool.fetchAll(db, sql: "SELECT auto_approve_window FROM runs ORDER BY id")
    }
    #expect(backfilled == [false, false])
  }
}
