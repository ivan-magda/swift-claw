import ClawCore
import Foundation
import GRDB

public struct SessionMessageStoreGRDB: SessionMessageStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func loadOrCreateSession(sessionKey: String, now: Date) throws(StoreError) -> Int64 {
    try database.writeMapping { db in
      try Self.upsertSession(db, sessionKey: sessionKey, now: now)
    }
  }

  public func claimCommandUpdate(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws(StoreError) -> CommandClaim {
    try database.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateId: updateId,
        claimedAt: now
      )

      guard newlyClaimed else {
        return .duplicate
      }

      let sessionId = try Self.upsertSession(db, sessionKey: sessionKey, now: now)
      return .claimed(sessionId: sessionId)
    }
  }

  public func findSession(sessionKey: String) throws(StoreError) -> Int64? {
    try database.readMapping { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT id FROM sessions WHERE session_key = ?",
        arguments: [sessionKey]
      )
    }
  }

  public func claimAndPersistInbound(_ inbound: InboundMessage) throws(StoreError) -> ClaimResult {
    try database.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateId: inbound.updateId,
        claimedAt: inbound.ts
      )

      guard newlyClaimed else {
        return ClaimResult(
          newlyClaimed: false,
          sessionId: nil,
          messageId: nil,
          runId: nil,
          triggerMessageId: nil
        )
      }

      let sessionId = try Self.upsertSession(db, sessionKey: inbound.sessionKey, now: inbound.ts)
      // Owner-typed input is trusted-tier; machine-derived inbound text (a voice transcript)
      // arrives `.untrusted` and taints the session in this same fused write, so context assembly
      // fences it and the exfil gate arms without any tool having run.
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId,
          MessageRole.user.rawValue,
          inbound.text,
          inbound.provenance.rawValue,
          inbound.ts,
        ]
      )
      let messageId = db.lastInsertedRowID

      if inbound.provenance == .untrusted {
        try RunStoreGRDB.setSessionTainted(db, sessionId: sessionId, now: inbound.ts)
      }

      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_message_id)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId,
          RunState.pending.rawValue,
          inbound.ts,
          inbound.ts,
          messageId,
        ]
      )
      let runId = db.lastInsertedRowID

      return ClaimResult(
        newlyClaimed: true,
        sessionId: sessionId,
        messageId: messageId,
        runId: runId,
        triggerMessageId: messageId
      )
    }
  }

  public func loadContextSnapshot(
    sessionId: Int64,
    throughMessageId: Int64,
    limit: Int
  ) throws(StoreError) -> SessionContextSnapshot {
    try database.readMapping { db in
      let session = try Row.fetchOne(
        db,
        sql: "SELECT window_start_message_id, tainted, has_private_data FROM sessions WHERE id = ?",
        arguments: [sessionId]
      )

      let windowStartMessageId: Int64?
      let isTainted: Bool
      let hasPrivateData: Bool
      if let session {
        windowStartMessageId = session["window_start_message_id"]
        isTainted = session["tainted"]
        hasPrivateData = session["has_private_data"]
      } else {
        windowStartMessageId = nil
        isTainted = false
        hasPrivateData = false
      }

      // The window is bounded by CONVERSATIONAL rows: find the id of the `limit`-th
      // newest user/assistant row, then load ALL rows from it through the trigger. Tool rows ride
      // along; the boundary is a conversational row by construction, so an exchange is always
      // included or excluded whole, and tool-row inflation can never evict conversation.
      let windowStart = windowStartMessageId ?? 0
      let boundaryId =
        try Int64.fetchOne(
          db,
          sql: """
            SELECT id FROM messages
            WHERE session_id = ? AND id > ? AND id <= ?
              AND role IN ('\(MessageRole.user.rawValue)', '\(MessageRole.assistant.rawValue)')
            ORDER BY id DESC
            LIMIT 1 OFFSET ?
            """,
          arguments: [sessionId, windowStart, throughMessageId, max(0, limit - 1)]
        ) ?? 0

      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, role, content, provenance, tool_calls, tool_call_id,
            \(ProviderStateCoding.selection)
          FROM messages
          WHERE session_id = ? AND id > ? AND id <= ? AND id >= ?
          ORDER BY id ASC
          """,
        arguments: [sessionId, windowStart, throughMessageId, boundaryId]
      )

      let history = try rows.map(Self.decodeStoredMessage)

      // The SELECT already returns `id`, so the id remap stays valid.
      let messageIds = rows.map { row in
        row["id"] as Int64
      }

      return SessionContextSnapshot(
        history: history,
        historyMessageIds: messageIds,
        windowStartMessageId: windowStartMessageId,
        isTainted: isTainted,
        hasPrivateData: hasPrivateData
      )
    }
  }

  public func resetWindowAndDetaint(sessionId: Int64, now: Date) throws(StoreError) {
    try database.writeMapping { db in
      try Self.resetWindowAndDetaint(db, sessionId: sessionId, now: now)
    }
  }

  /// Resets the context window boundary to the current message high-water mark and clears both
  /// sticky flags (taint, private data) atomically. Reused inside existing transactions
  /// (e.g. `CommandStoreGRDB`).
  static func resetWindowAndDetaint(_ db: Database, sessionId: Int64, now: Date) throws {
    // The boundary and detaint must move atomically so `/new` cannot expose a mixed session state.
    let boundary =
      try Int64.fetchOne(
        db,
        sql: "SELECT COALESCE(MAX(id), 0) FROM messages WHERE session_id = ?",
        arguments: [sessionId]
      ) ?? 0

    try db.execute(
      sql: """
        UPDATE sessions
        SET window_start_message_id = ?, tainted = 0, has_private_data = 0, updated_ts = ?
        WHERE id = ?
        """,
      arguments: [boundary, now, sessionId]
    )
  }

  /// Upsert keyed on `session_key`; returns the row id. Reused inside `claimAndPersistInbound`'s
  /// transaction so the session create stays in the one fused write.
  static func upsertSession(_ db: Database, sessionKey: String, now: Date) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO sessions(session_key, created_ts, updated_ts, tainted) VALUES (?, ?, ?, 0)
        ON CONFLICT(session_key) DO UPDATE SET updated_ts = excluded.updated_ts
        """,
      arguments: [sessionKey, now, now]
    )

    let sessionId = try Int64.fetchOne(
      db,
      sql: "SELECT id FROM sessions WHERE session_key = ?",
      arguments: [sessionKey]
    )
    guard let sessionId else {
      throw StoreError.unexpected("session upsert returned no row id")
    }

    return sessionId
  }

  /// Decodes a `messages` row, failing **closed** on an unrecognized persisted enum value:
  /// `provenance` is the trust tier — a corrupted value must not silently become the
  /// permissive `.trusted` and unfence content the moment assembly keys off it. Same rule as
  /// `MemoryStoreGRDB.decodeItem`.
  ///
  /// Replay state is the opposite call, for the opposite reason: it is optional metadata no message
  /// needs to be read, understood, or answered, so an invalid one is dropped and the message is
  /// still delivered — the same leniency `tool_calls` already gets. Refusing the row instead would
  /// let one bad blob take down a session that reads perfectly well without it.
  static func decodeStoredMessage(_ row: Row) throws -> StoredMessage {
    let rowId: Int64 = row["id"]

    guard
      let role = MessageRole(rawValue: row["role"]),
      let provenance = Provenance(rawValue: row["provenance"])
    else {
      throw StoreError.unexpected("messages row \(rowId) has an unrecognized role or provenance")
    }

    return StoredMessage(
      role: role,
      content: row["content"],
      provenance: provenance,
      toolCallsJSON: row["tool_calls"],
      toolCallId: row["tool_call_id"],
      providerState: ProviderStateCoding.decode(row)
    )
  }
}
