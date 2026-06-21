import ClawCore
import Foundation
import GRDB

public struct SessionMessageStoreGRDB: SessionMessageStore {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func loadOrCreateSession(sessionKey: String, now: Date) throws -> Int64 {
    try writer.write { db in
      try Self.upsertSession(db, sessionKey: sessionKey, now: now)
    }
  }

  public func claimAndPersistInbound(_ inbound: InboundMessage) throws -> ClaimResult {
    try writer.write { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateId: inbound.updateId,
        claimedAt: inbound.ts
      )

      guard newlyClaimed else {
        return ClaimResult(newlyClaimed: false, sessionId: nil, messageId: nil)
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

      return ClaimResult(
        newlyClaimed: true,
        sessionId: sessionId,
        messageId: db.lastInsertedRowID
      )
    }
  }

  public func loadRecentMessages(sessionId: Int64, limit: Int) throws -> [StoredMessage] {
    try writer.read { db in
      // Most-recent `limit` by (ts, id) DESC, then reversed to oldest-first for context assembly.
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT role, content, provenance FROM messages
          WHERE session_id = ? ORDER BY ts DESC, id DESC LIMIT ?
          """,
        arguments: [sessionId, limit]
      )
      return rows.reversed().map { row in
        StoredMessage(
          role: MessageRole(rawValue: row["role"]) ?? .user,
          content: row["content"],
          provenance: Provenance(rawValue: row["provenance"]) ?? .trusted
        )
      }
    }
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
