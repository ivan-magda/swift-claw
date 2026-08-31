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
        table.column("updated_ts", .datetime).notNull()
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
        table.column("dedup_key", .text).notNull().unique()
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
        table.column("tool", .text)
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
    migrator.registerMigration("v6") { db in
      try db.create(table: "scheduled_jobs") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("owner_chat_id", .integer).notNull()
        table.column("label", .text).notNull()
        table.column("prompt", .text).notNull()
        table.column("recurrence", .text)
        table.column("timezone", .text).notNull()
        table.column("next_occurrence", .integer)
        table.column("last_fired_at", .integer)
        table.column("status", .text).notNull()
        table.column("session_id", .integer).references("sessions", onDelete: .setNull)
        table.column("created_ts", .integer).notNull()
        table.column("updated_ts", .integer).notNull()
      }
      try db.create(
        index: "index_scheduled_jobs_status_next_occurrence",
        on: "scheduled_jobs",
        columns: ["status", "next_occurrence"],
        condition: Column("next_occurrence") != nil
      )
      try db.alter(table: "runs") { table in
        table.add(column: "origin", .text).notNull().defaults(to: "interactive")
        table.add(column: "job_id", .integer).references("scheduled_jobs")
      }
      try db.create(table: "scheduler_state") { table in
        table.primaryKey("id", .integer).check { id in id == 1 }
        table.column("last_tick_at", .integer)
        table.column("last_misfire_at", .integer)
        table.column("last_misfire_skipped_count", .integer).notNull().defaults(to: 0)
        table.column("last_heartbeat_at", .integer)
        table.column("heartbeat_count_day", .text)
        table.column("heartbeat_count", .integer).notNull().defaults(to: 0)
      }
    }
    migrator.registerMigration("v7") { db in
      try db.create(table: "provider_usage_new") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("run_id", .integer).references("runs", onDelete: .cascade)
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
      try db.execute(sql: "INSERT INTO provider_usage_new SELECT * FROM provider_usage")
      try db.drop(table: "provider_usage")
      try db.rename(table: "provider_usage_new", to: "provider_usage")
    }
    migrator.registerMigration("v8") { db in
      try db.create(table: "approvals") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("run_id", .integer).notNull().references("runs", onDelete: .cascade)
        table.column("session_id", .integer).notNull()
          .references("sessions", onDelete: .cascade)
        table.column("state", .text).notNull()
        table.column("tool", .text).notNull()
        table.column("canonical_args", .text).notNull()
        table.column("canonical_target", .text).notNull()
        table.column("args_hash", .text).notNull()
        table.column("policy_version", .text).notNull()
        table.column("owner_user_id", .integer).notNull()
        table.column("nonce", .text).notNull().unique()
        table.column("observation_message_id", .integer).notNull()
        table.column("tool_call_id", .text).notNull()
        table.column("reason", .text).notNull()
        table.column("prompt_message_id", .integer)
        table.column("created_ts", .integer).notNull()
        table.column("expires_ts", .integer).notNull()
        table.column("resolved_ts", .integer)
      }
      try db.create(
        index: "index_approvals_pending_run",
        on: "approvals",
        columns: ["run_id"],
        options: [.unique],
        condition: Column("state") == ApprovalState.pending.rawValue
      )
      try db.alter(table: "runs") { table in
        table.add(column: "policy_version", .text)
      }
      try db.alter(table: "sessions") { table in
        table.add(column: "has_private_data", .boolean).notNull().defaults(to: false)
      }
      try db.alter(table: "outbound_deliveries") { table in
        table.add(column: "approval_id", .integer).references("approvals")
        table.add(column: "reply_markup", .text)
      }
    }
    migrator.registerMigration("v9") { db in
      try rebuildMessagesWithProviderState(db)
      try rebuildProviderUsageWithCallIdentity(db)
    }
    migrator.registerMigration("v10") { db in
      // Telegram's own message id, distinct from `trigger_message_id` (a `messages` row id): it is
      // the reply target a group answer must address, and it has no other durable home.
      try db.alter(table: "runs") { table in
        table.add(column: "trigger_telegram_message_id", .integer)
      }
      try db.alter(table: "outbound_deliveries") { table in
        table.add(column: "message_thread_id", .integer)
        table.add(column: "reply_to_message_id", .integer)
      }
    }
    migrator.registerMigration("v11") { db in
      try db.alter(table: "runs") { table in
        table.add(column: "auto_approve_window", .boolean).notNull().defaults(to: false)
      }
    }
    return migrator
  }

  /// Translates a raw GRDB/SQLite failure into a domain `StoreError` at the persistence seam (a
  /// `StoreError` a store threw deliberately passes through unchanged). This is the single place
  /// SQLite codes become typed errors; the `default` arm keeps any raw `DatabaseError` from
  /// leaking, and the returned type makes `throws(StoreError)` seams compiler-checkable. Extend the
  /// `switch` to classify a new failure mode and every `writeMapping`/`readMapping` call site picks
  /// it up with no call-site change. Matching on the *primary* result code coarsely buckets the
  /// extended codes (`SQLITE_IOERR_*`, `SQLITE_BUSY_*`); a `switch` (not a lookup table) keeps
  /// special-casing an extended code possible later.
  public static func classifyError(_ error: any Error) -> StoreError {
    if let storeError = error as? StoreError {
      return storeError
    }
    guard let databaseError = error as? DatabaseError else {
      return StoreError.unexpected("\(error)")
    }

    switch databaseError.resultCode.primaryResultCode {
    case .SQLITE_FULL:
      return StoreError.diskFull
    default:
      return StoreError.unexpected("\(databaseError)")
    }
  }
}
