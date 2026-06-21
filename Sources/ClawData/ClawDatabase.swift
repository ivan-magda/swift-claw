import ClawCore
import Foundation
import GRDB

public enum ClawDatabase {
  public static func makeConfiguration(busyTimeout: TimeInterval = 5) -> Configuration {
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.busyMode = .timeout(busyTimeout)
    return config
  }

  public static func makePool(path: String) throws -> DatabasePool {
    do {
      return try DatabasePool(path: path, configuration: makeConfiguration())
    } catch {
      throw StoreError.openFailed("\(error)")
    }
  }

  /// Tests use an in-memory queue (WAL is unavailable in-memory).
  public static func makeInMemoryQueue() throws -> DatabaseQueue {
    try DatabaseQueue(configuration: makeConfiguration())
  }

  public static func migrate(_ writer: any DatabaseWriter) throws {
    do {
      try migrator.migrate(writer)
    } catch {
      throw StoreError.migrationFailed("\(error)")
    }
  }

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.create(table: "allowlist") { table in
        table.column("user_id", .integer).primaryKey()
        table.column("added_at", .datetime).notNull()
      }
      try db.create(table: "processed_updates") { table in
        table.column("update_id", .integer).primaryKey()
        table.column("claimed_at", .datetime).notNull()
      }
      try db.create(table: "update_cursor") { table in
        table.column("id", .integer).primaryKey()
        table.column("last_update_id", .integer).notNull()
      }
    }
    migrator.registerMigration("v2") { db in
      try db.create(table: "sessions") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("session_key", .text).notNull().unique()
        table.column("created_ts", .datetime).notNull()
        table.column("updated_ts", .datetime).notNull()
        table.column("summary_ref", .text)
        table.column("tainted", .boolean).notNull().defaults(to: false)
      }
      try db.create(table: "runs") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("session_id", .integer).notNull()
          .references("sessions", onDelete: .cascade)
        table.column("state", .text).notNull()
        table.column("created_ts", .datetime).notNull()
        table.column("updated_ts", .datetime).notNull()  // lease for the boot sweep
        table.column("input_tokens", .integer)
        table.column("output_tokens", .integer)
        table.column("cost_usd", .double)
      }
      try db.create(table: "messages") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("session_id", .integer).notNull()
          .references("sessions", onDelete: .cascade)
        table.column("run_id", .integer).references("runs", onDelete: .setNull)
        table.column("role", .text).notNull()
        table.column("content", .text).notNull()
        table.column("provenance", .text).notNull()
        table.column("ts", .datetime).notNull()
        table.column("prompt_tokens", .integer)
        table.column("completion_tokens", .integer)
      }
      try db.create(table: "provider_usage") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("run_id", .integer).notNull().references("runs", onDelete: .cascade)
        table.column("session_id", .integer).notNull()
          .references("sessions", onDelete: .cascade)
        table.column("model", .text).notNull()
        table.column("prompt_tokens", .integer).notNull()
        table.column("completion_tokens", .integer).notNull()
        table.column("cost_usd", .double).notNull()
        table.column("cost_source", .text).notNull()
        table.column("is_estimated", .boolean).notNull()
        table.column("ts", .datetime).notNull()
      }
      try db.create(table: "outbound_deliveries") { table in
        table.column("run_id", .integer).notNull().references("runs", onDelete: .cascade)
        table.column("step_index", .integer).notNull()
        table.column("chat_id", .integer).notNull()
        // Deterministic dedup key = "run_id:step_index" (NOT a UUID/wall-clock).
        table.column("dedup_key", .text).notNull().unique()
        // the markdown to (re-)send; outbox is self-contained
        table.column("payload", .text).notNull()
        table.column("payload_hash", .text).notNull()
        table.column("telegram_message_id", .integer)
        table.column("status", .text).notNull()
        table.column("created_ts", .datetime).notNull()
        table.column("sent_ts", .datetime)
      }
      try db.create(table: "audit_events") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("ts", .datetime).notNull()
        table.column("actor", .text).notNull()
        table.column("action", .text).notNull()
        table.column("tool", .text)  // nullable now → no Inc-3 migration (F9)
        table.column("args_redacted", .text).notNull()
        table.column("result_size", .integer).notNull()
        table.column("decision", .text).notNull()
        table.column("run_id", .integer)
        table.column("session_id", .integer)
      }
    }
    return migrator
  }

  /// Maps a raw GRDB/SQLite error to `StoreError.diskFull` when the primary result code is
  /// `SQLITE_FULL` — the gateway reacts to a full disk with a long backoff (F23).
  public static func isDiskFullError(_ error: any Error) -> Bool {
    (error as? DatabaseError)?.resultCode.primaryResultCode == .SQLITE_FULL
  }
}
