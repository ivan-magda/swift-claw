import GRDB

extension ClawDatabase {
  static func createJournalTables(_ db: Database) throws {
    try db.alter(table: "runs") { table in
      table.add(column: "journal_admission", .blob)
    }
    try db.alter(table: "coder_jobs") { table in
      table.add(column: "journal_scope", .blob)
      table.add(column: "journal_terminal_ts", .datetime)
    }
    try db.create(table: "journal_sources") { table in
      table.column("source_id", .text).primaryKey()
      table.column("owner_user_id", .integer).notNull()
      table.column("day", .text).notNull()
      table.column("timezone", .text).notNull()
      table.column("session_id", .integer).notNull()
      table.column("activity_ts", .datetime).notNull()
      table.column("payload", .blob)
      table.column("state", .text).notNull()
      table.column("due", .boolean).notNull().defaults(to: false)
      table.column("batch_id", .text)
    }
    try db.create(
      index: "journal_pending",
      on: "journal_sources",
      columns: ["owner_user_id", "state", "activity_ts"]
    )
    try db.create(table: "journal_batches") { table in
      table.column("id", .text).primaryKey()
      table.column("owner_user_id", .integer).notNull()
      table.column("day", .text).notNull()
      table.column("batch", .blob).notNull()
      table.column("provider_call_id", .text).notNull().unique()
      table.column("saved_usage", .blob).notNull()
      table.column("started_ts", .datetime).notNull()
      table.column("state", .text).notNull()
      table.column("outcome", .blob)
    }
    try db.create(index: "journal_started", on: "journal_batches", columns: ["started_ts"])
    try db.create(table: "journal_status") { table in
      table.column("owner_user_id", .integer).primaryKey()
      table.column("last_outcome", .blob)
      table.column("last_outcome_ts", .datetime)
      table.column("skipped_count", .integer).notNull().defaults(to: 0)
      table.column("interrupted_count", .integer).notNull().defaults(to: 0)
      table.column("last_redacted_error", .text)
    }
  }
}
