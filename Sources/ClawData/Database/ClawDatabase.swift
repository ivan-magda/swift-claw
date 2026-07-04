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
        // the markdown to (re-)send
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
    migrator.registerMigration("v3") { db in
      try db.alter(table: "sessions") { table in
        table.add(column: "window_start_message_id", .integer).notNull().defaults(to: 0)
      }
      try db.alter(table: "runs") { table in
        table.add(column: "trigger_message_id", .integer)
      }
    }
    migrator.registerMigration("v4") { db in
      try db.create(table: "memory_items") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("text", .text).notNull()
        table.column("kind", .text).notNull()
        table.column("sensitivity", .text).notNull()
        table.column("importance", .integer).notNull()
        table.column("source", .text).notNull()
        table.column("session_id", .integer)
          .references("sessions", onDelete: .setNull)
        table.column("created_at", .datetime).notNull()
      }
      try db.create(
        index: "index_memory_items_created_at",
        on: "memory_items",
        columns: ["created_at"]
      )
      try db.create(index: "index_memory_items_kind", on: "memory_items", columns: ["kind"])
      // messages FTS5 index. GRDB's FTS5 builder - never raw SQL.
      // `synchronize` wires external content (content_rowid = messages.id), the ordered
      // AFTER INSERT/UPDATE/DELETE sync triggers, and the initial backfill of existing rows.
      try db.create(virtualTable: "messages_fts", using: FTS5()) { table in
        table.synchronize(withTable: "messages")
        table.tokenizer = .unicode61(diacritics: .remove)
        table.column("content")
      }
    }
    migrator.registerMigration("v5") { db in
      try db.alter(table: "messages") { table in
        table.add(column: "tool_calls", .text)
        table.add(column: "tool_call_id", .text)
      }
    }
    return migrator
  }

  /// Translates a raw GRDB/SQLite failure into a domain `StoreError` at the persistence seam (a
  /// non-`DatabaseError` is already domain-typed and passes through). This is the single place
  /// SQLite codes become typed errors (F23); the `default` arm keeps any raw `DatabaseError` from
  /// leaking. Extend the `switch` to classify a new failure mode and every
  /// `writeMapping`/`readMapping` call site picks it up with no call-site change. Matching on the
  /// *primary* result code coarsely buckets the extended codes (`SQLITE_IOERR_*`, `SQLITE_BUSY_*`);
  /// a `switch` (not a lookup table) keeps special-casing an extended code possible later.
  public static func classifyError(_ error: any Error) -> any Error {
    guard let databaseError = error as? DatabaseError else {
      return error
    }

    switch databaseError.resultCode.primaryResultCode {
    case .SQLITE_FULL:
      return StoreError.diskFull
    default:
      return StoreError.unexpected("\(databaseError)")
    }
  }
}

extension DatabaseReader {
  /// A store read whose GRDB failures are translated to domain `StoreError`s at the seam, so a raw
  /// `DatabaseError` never leaks past the store boundary. Drop-in for `read` — same call-site
  /// shape, no nesting. `DatabaseWriter` refines `DatabaseReader`, so writers inherit this too.
  func readMapping<Value>(_ value: (Database) throws -> Value) throws -> Value {
    do {
      return try read(value)
    } catch {
      throw ClawDatabase.classifyError(error)
    }
  }
}

extension DatabaseWriter {
  /// A store write whose GRDB failures are translated to domain `StoreError`s at the seam (e.g. a
  /// full disk → `StoreError.diskFull`, F23). Drop-in for `write` — same call-site shape, no
  /// nesting; a new turn-path write gets domain-error handling just by choosing this method.
  func writeMapping<Value>(_ updates: (Database) throws -> Value) throws -> Value {
    do {
      return try write(updates)
    } catch {
      throw ClawDatabase.classifyError(error)
    }
  }
}
