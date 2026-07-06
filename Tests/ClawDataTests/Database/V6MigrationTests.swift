import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V6MigrationTests {
  private func columnNames(_ queue: DatabaseQueue, table: String) throws -> [String] {
    try queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
        row["name"] as String
      }
    }
  }

  @Test func vSixCreatesTheSchedulingTablesAndRunColumns() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then — the required §4.1 columns are present (superset; order and extra columns not pinned)
    let scheduledJobColumns = Set(try columnNames(queue, table: "scheduled_jobs"))
    #expect(
      scheduledJobColumns.isSuperset(of: [
        "id", "owner_chat_id", "label", "prompt", "recurrence", "timezone",
        "next_occurrence", "last_fired_at", "status", "session_id", "created_ts", "updated_ts",
      ])
    )

    let runColumns = try columnNames(queue, table: "runs")
    #expect(runColumns.contains("origin"))
    #expect(runColumns.contains("job_id"))

    let schedulerStateColumns = Set(try columnNames(queue, table: "scheduler_state"))
    #expect(
      schedulerStateColumns.isSuperset(of: [
        "id", "last_tick_at", "last_misfire_at", "last_misfire_skipped_count",
        "last_heartbeat_at", "heartbeat_count_day", "heartbeat_count",
      ])
    )
  }

  @Test func tickerIndexIsPartialOnStatusAndNextOccurrence() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then — a PARTIAL index (WHERE clause) so terminal NULL-next rows never bloat the scan
    let indexSQL = try queue.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT sql FROM sqlite_master
          WHERE type = 'index' AND name = 'index_scheduled_jobs_status_next_occurrence'
          """
      )
    }
    #expect(indexSQL?.contains("status") == true)
    #expect(indexSQL?.contains("next_occurrence") == true)
    #expect(indexSQL?.localizedCaseInsensitiveContains("where") == true)
  }

  @Test func schedulerStateAcceptsOnlyTheSingletonRow() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)

    // when — the singleton row inserts; any other id violates the CHECK
    try queue.write { db in
      try db.execute(sql: "INSERT INTO scheduler_state(id) VALUES (1)")
    }

    // then
    #expect(throws: (any Error).self) {
      try queue.write { db in
        try db.execute(sql: "INSERT INTO scheduler_state(id) VALUES (2)")
      }
    }
    let skipped = try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT last_misfire_skipped_count FROM scheduler_state WHERE id = 1"
      )
    }
    #expect(skipped == 0)  // NOT NULL defaults let partial upserts work
  }

  @Test func vSixUpgradesAPopulatedVFiveDatabase() throws {
    // given — a v5 database that already holds a session, a message, and a run
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrator.migrate(queue, upTo: "v5")
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
      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_message_id)
          VALUES (1, 'DONE', ?, ?, 1)
          """,
        arguments: [Date(), Date()]
      )
    }

    // when
    try ClawDatabase.migrate(queue)

    // then — the old run is backfilled by the column default, with no job linkage
    let runRow = try queue.read { db in
      try Row.fetchOne(db, sql: "SELECT origin, job_id FROM runs WHERE id = 1")
    }
    #expect(runRow?["origin"] == "interactive")
    #expect((runRow?["job_id"] as Int64?) == nil)

    // and a scheduled_jobs insert works against the upgraded schema
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO scheduled_jobs(owner_chat_id, label, prompt, recurrence, timezone,
            next_occurrence, status, created_ts, updated_ts)
          VALUES (7, 'digest', 'Summarize my unread items', NULL, 'Europe/Berlin',
            1782000000, 'ACTIVE', 1781990000, 1781990000)
          """
      )
    }
    let status = try queue.read { db in
      try String.fetchOne(db, sql: "SELECT status FROM scheduled_jobs WHERE id = 1")
    }
    #expect(status == "ACTIVE")
  }
}
