import ClawCore
import Foundation
import GRDB

public struct RetrieverGRDB: Retriever {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    limit: Int
  ) throws(StoreError) -> [RecallHit] {
    // A tokenless query (empty/punctuation) yields nil -> zero results; never raw-interpolate text.
    guard let pattern = FTS5Pattern(matchingAnyTokenIn: query) else {
      return []
    }

    return try database.readMapping { db in
      // messages_fts.rowid == messages.id (external content). BM25 is negative; lower = better, so
      // ORDER BY is ASC. RecallScore negates it back so higher = better for policy/telemetry.
      var sql = """
        SELECT m.id, m.session_id, m.role, m.content, m.ts, bm25(messages_fts) AS bm25_score
        FROM messages m
        JOIN messages_fts ON messages_fts.rowid = m.id
        WHERE messages_fts MATCH ?
          AND m.role IN ('\(MessageRole.user.rawValue)', '\(MessageRole.assistant.rawValue)')
        """
      var arguments: StatementArguments = [pattern]

      if let windowStart = windowStartMessageId {
        // Dedup against the current session's in-window range.
        sql += "\n  AND NOT (m.session_id = ? AND m.id >= ?)"
        arguments += [currentSessionId, windowStart]
      }

      if excludedMessageIds.isEmpty == false {
        let placeholders = excludedMessageIds.map { _ in "?" }.joined(separator: ", ")
        sql += "\n  AND m.id NOT IN (\(placeholders))"
        arguments += StatementArguments(excludedMessageIds)
      }

      sql += "\n  ORDER BY bm25(messages_fts) ASC\n  LIMIT ?"
      arguments += [limit]

      let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
      return try rows.map { row in
        // The SQL filters `role IN ('user','assistant')`, so an unknown role is unreachable
        // today — the guard keeps the decode direction fail-closed if that filter ever moves.
        guard let role = MessageRole(rawValue: row["role"]) else {
          throw StoreError.unexpected("messages row \(row["id"] as Int64) has an unrecognized role")
        }
        return RecallHit(
          id: row["id"],
          sessionId: row["session_id"],
          role: role,
          content: row["content"],
          score: RecallScore(sqliteBM25: row["bm25_score"]),
          createdAt: row["ts"]
        )
      }
    }
  }
}
