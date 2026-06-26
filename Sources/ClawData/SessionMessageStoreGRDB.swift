import ClawCore
import Foundation
import GRDB

public struct SessionMessageStoreGRDB: SessionMessageStore {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func loadOrCreateSession(sessionKey: String, now: Date) throws -> Int64 {
    try writer.writeMapping { db in
      try Self.upsertSession(db, sessionKey: sessionKey, now: now)
    }
  }

  public func claimAndPersistInbound(_ inbound: InboundMessage) throws -> ClaimResult {
    try writer.writeMapping { db in
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
      // Owner input is trusted-tier by definition; taint from tool/web output is tracked
      // separately via session.tainted, not at the message row (ARCHITECTURE.md §12).
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts)
          VALUES (?, 'user', ?, 'trusted', ?)
          """,
        arguments: [sessionId, inbound.text, inbound.ts]
      )
      let messageId = db.lastInsertedRowID

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

  public func loadContext(
    sessionId: Int64,
    throughMessageId: Int64,
    limit: Int
  ) throws -> [StoredMessage] {
    try writer.readMapping { db in
      // Limit the newest eligible rows first, then restore chronological order for the model.
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT role, content, provenance FROM (
            SELECT m.id, m.role, m.content, m.provenance
            FROM messages m
            JOIN sessions s ON s.id = m.session_id
            WHERE m.session_id = ?
              AND m.id > s.window_start_message_id
              AND m.id <= ?
            ORDER BY m.id DESC
            LIMIT ?
          )
          ORDER BY id ASC
          """,
        arguments: [sessionId, throughMessageId, limit]
      )

      return rows.map { row in
        StoredMessage(
          role: MessageRole(rawValue: row["role"]) ?? .user,
          content: row["content"],
          provenance: Provenance(rawValue: row["provenance"]) ?? .trusted
        )
      }
    }
  }

  public func resetWindowAndDetaint(sessionId: Int64, now: Date) throws {
    try writer.writeMapping { db in
      try Self.resetWindowAndDetaint(db, sessionId: sessionId, now: now)
    }
  }

  /// Resets the context window boundary to the current message high-water mark and clears the
  /// taint flag atomically. Reused inside existing transactions (e.g. `CommandStoreGRDB`).
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
        SET window_start_message_id = ?, tainted = 0, updated_ts = ?
        WHERE id = ?
        """,
      arguments: [boundary, now, sessionId]
    )
  }

  /// Upsert keyed on `session_key`; returns the row id. Reused inside `claimAndPersistInbound`'s
  /// transaction so the session create stays in the one fused write (F4).
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
}
