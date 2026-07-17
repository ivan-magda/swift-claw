import ClawCore
import Foundation
import GRDB

// MARK: - Schema V9 Rebuilds

extension ClawDatabase {
  /// Adds the replay-state pair to `messages`. The table is rebuilt rather than `ALTER`ed because
  /// SQLite can only attach a table-level CHECK at creation, and the pair rule — state and the
  /// issuer that minted it arrive together or not at all — is exactly a table-level invariant:
  /// state without an issuer names no adapter that could replay it, and an issuer without state
  /// claims a replay that does not exist. Both-null stays legal, which is every pre-v9 row.
  static func rebuildMessagesWithProviderState(_ db: Database) throws {
    // The FTS index is external-content: its rows are rowids into `messages`, maintained by
    // triggers ON `messages`. Dropping the table under a live index would leave the index
    // pointing at rows that no longer exist, so the index goes first and is rebuilt from the
    // finished table afterwards — which also repopulates it.
    try db.drop(table: "messages_fts")
    try db.dropFTS5SynchronizationTriggers(forTable: "messages_fts")

    try db.create(table: "messages_new") { table in
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
      table.column("tool_calls", .text)
      table.column("tool_call_id", .text)
      table.column("provider_state_issuer", .text)
      // Opaque bytes. Only the adapter that issued the state may interpret it, so the column
      // carries no affinity that would coerce the payload.
      table.column("provider_state", .blob)
      table.check(sql: "(provider_state_issuer IS NULL) = (provider_state IS NULL)")
    }
    // Columns are listed explicitly: a bare `SELECT *` would bind by position and silently
    // mis-seat every value if either table's column order ever drifted.
    try db.execute(
      sql: """
        INSERT INTO messages_new (id, session_id, run_id, role, content, provenance, ts,
          prompt_tokens, completion_tokens, tool_calls, tool_call_id)
        SELECT id, session_id, run_id, role, content, provenance, ts, prompt_tokens,
          completion_tokens, tool_calls, tool_call_id
        FROM messages
        """
    )
    try db.drop(table: "messages")
    try db.rename(table: "messages_new", to: "messages")

    // Same shape as v4, so the index the rebuild leaves behind is the one the rest of the schema
    // was written against. `synchronize` backfills from the finished table, restoring every
    // carried-forward row's index entry against its preserved id.
    try db.create(virtualTable: "messages_fts", using: FTS5()) { table in
      table.synchronize(withTable: "messages")
      table.tokenizer = .unicode61(diacritics: .remove)
      table.column("content")
    }
  }

  /// Gives every usage row the provider-call identity that makes insertion idempotent. Existing
  /// rows are keyed off the row id the migration finds, so the assignment is deterministic and
  /// re-running it on a copy of the same database produces the same identities.
  static func rebuildProviderUsageWithCallIdentity(_ db: Database) throws {
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
      table.column("provider_call_id", .text).notNull()
    }
    try db.execute(
      sql: """
        INSERT INTO provider_usage_new (id, run_id, session_id, model, prompt_tokens,
          completion_tokens, cost_usd, cost_source, is_estimated, ts, provider_call_id)
        SELECT id, run_id, session_id, model, prompt_tokens, completion_tokens, cost_usd,
          cost_source, is_estimated, ts, 'legacy:' || id
        FROM provider_usage
        """
    )
    try db.drop(table: "provider_usage")
    try db.rename(table: "provider_usage_new", to: "provider_usage")
    try db.create(
      index: "index_provider_usage_provider_call_id",
      on: "provider_usage",
      columns: ["provider_call_id"],
      options: [.unique]
    )
  }
}
