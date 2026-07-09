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
    migrator.registerMigration("v6") { db in
      // Spec §4.1. Occurrence/timestamp columns are UTC epoch-second INTEGERs so the fused
      // claim's compare-and-advance (§5.2) is exact integer equality, never a string compare.
      try db.create(table: "scheduled_jobs") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("owner_chat_id", .integer).notNull()
        table.column("label", .text).notNull()
        table.column("prompt", .text).notNull()
        // {"schema_version":1,"rule":<RecurrenceRule JSON>}; NULL ⇔ one-shot (D2)
        table.column("recurrence", .text)
        table.column("timezone", .text).notNull()
        table.column("next_occurrence", .integer)
        table.column("last_fired_at", .integer)
        table.column("status", .text).notNull()
        table.column("session_id", .integer).references("sessions", onDelete: .setNull)
        table.column("created_ts", .integer).notNull()
        table.column("updated_ts", .integer).notNull()
      }
      // Partial: terminal rows keep next_occurrence NULL, so the ticker scan never sees them.
      try db.create(
        index: "index_scheduled_jobs_status_next_occurrence",
        on: "scheduled_jobs",
        columns: ["status", "next_occurrence"],
        condition: Column("next_occurrence") != nil
      )
      try db.alter(table: "runs") { table in
        // 'interactive' | 'scheduled' | 'heartbeat' — backfill is the default, no data rewrite.
        table.add(column: "origin", .text).notNull().defaults(to: "interactive")
        table.add(column: "job_id", .integer).references("scheduled_jobs")
      }
      // Spec §4.3: one row, updated inside tick/claim transactions; doctor reads it from its
      // separate process. due_count is deliberately NOT stored (computed by query).
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
      // Spec §4.1. Timestamps are UTC epoch-second INTEGERs (the v6 idiom) so the expiry
      // sweep's `expires_ts <= now` compare is exact integer arithmetic.
      try db.create(table: "approvals") { table in
        table.autoIncrementedPrimaryKey("id")  // never exposed in callback data (§4.1)
        table.column("run_id", .integer).notNull().references("runs", onDelete: .cascade)
        table.column("session_id", .integer).notNull()
          .references("sessions", onDelete: .cascade)
        table.column("state", .text).notNull()  // PENDING | APPROVED | REJECTED | EXPIRED
        table.column("tool", .text).notNull()
        table.column("canonical_args", .text).notNull()  // the exact recorded args that execute
        table.column("canonical_target", .text).notNull()
        table.column("args_hash", .text).notNull()
        table.column("policy_version", .text).notNull()  // copied from the run row (§3.2)
        table.column("owner_user_id", .integer).notNull()
        table.column("nonce", .text).notNull().unique()
        table.column("observation_message_id", .integer).notNull()
        table.column("tool_call_id", .text).notNull()
        table.column("reason", .text).notNull()  // ask_tier | exfil_trifecta
        table.column("prompt_message_id", .integer)
        table.column("created_ts", .integer).notNull()
        table.column("expires_ts", .integer).notNull()
        table.column("resolved_ts", .integer)
      }
      // At most one live approval per run, enforced by the schema, not by convention (§4.1).
      try db.create(
        index: "index_approvals_pending_run",
        on: "approvals",
        columns: ["run_id"],
        options: [.unique],
        condition: Column("state") == "PENDING"
      )
      try db.alter(table: "runs") { table in
        table.add(column: "policy_version", .text)
      }
      try db.alter(table: "sessions") { table in
        table.add(column: "has_private_data", .boolean).notNull().defaults(to: false)
      }
      // Additive nullable columns: pre-upgrade PENDING deliveries stay valid; the button
      // envelope is not smuggled into `payload` (§4.1).
      try db.alter(table: "outbound_deliveries") { table in
        table.add(column: "approval_id", .integer).references("approvals")
        table.add(column: "reply_markup", .text)
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
