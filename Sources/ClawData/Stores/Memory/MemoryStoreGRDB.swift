import ClawCore
import Foundation
import GRDB

public struct MemoryStoreGRDB: MemoryStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func list(kind: MemoryKind?, limit: Int) throws(StoreError) -> [MemoryItem] {
    try database.readMapping { db in
      let rows: [Row]
      if let kind {
        rows = try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM memory_items
            WHERE kind = ?
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """,
          arguments: [kind.rawValue, limit]
        )
      } else {
        rows = try Row.fetchAll(
          db,
          sql: "SELECT * FROM memory_items ORDER BY created_at DESC, id DESC LIMIT ?",
          arguments: [limit]
        )
      }
      return try rows.map(Self.decodeItem)
    }
  }

  public func get(id: Int64) throws(StoreError) -> MemoryItem? {
    try database.readMapping { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM memory_items WHERE id = ?",
          arguments: [id]
        )
      else {
        return nil
      }
      return try Self.decodeItem(row)
    }
  }

  public func fetchRanked(excludeSensitive: Bool, limit: Int) throws(StoreError) -> [MemoryItem] {
    try database.readMapping { db in
      // Pure SQL ordering; the grapheme/budget fill is MemoryRanker's job.
      let sensitivityFilter = excludeSensitive ? "WHERE sensitivity = 'normal'" : ""
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM memory_items
          \(sensitivityFilter)
          ORDER BY importance DESC, created_at DESC, id DESC
          LIMIT ?
          """,
        arguments: [limit]
      )
      return try rows.map(Self.decodeItem)
    }
  }

  /// Inserts one memory item within the caller's transaction and returns it with its assigned rowid.
  static func insertItem(_ db: Database, item: NewMemoryItem, now: Date) throws -> MemoryItem {
    try db.execute(
      sql: """
        INSERT INTO memory_items(text, kind, sensitivity, importance, \
        source, session_id, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        item.text,
        item.kind.rawValue,
        item.sensitivity.rawValue,
        item.importance.rawValue,
        item.source.rawValue,
        item.sessionId,
        now,
      ]
    )
    return MemoryItem(
      id: db.lastInsertedRowID,
      text: item.text,
      kind: item.kind,
      sensitivity: item.sensitivity,
      importance: item.importance,
      source: item.source,
      sessionId: item.sessionId,
      createdAt: now
    )
  }

  /// Decodes a `memory_items` row, failing **closed** on any unrecognized persisted enum value: a
  /// corrupted `sensitivity`/`source` must not silently become the permissive `.normal`/`.owner`
  /// and falsify the taint guard or `/memory` provenance. Context reads degrade by omitting the row
  /// at the assembler boundary, not by inventing a value here.
  static func decodeItem(_ row: Row) throws -> MemoryItem {
    let rowId: Int64 = row["id"]

    guard
      let kind = MemoryKind(rawValue: row["kind"]),
      let sensitivity = Sensitivity(rawValue: row["sensitivity"]),
      let importance = Importance(rawValue: row["importance"]),
      let source = MemorySource(rawValue: row["source"])
    else {
      throw StoreError.unexpected("memory_items row \(rowId) has an unrecognized enum value")
    }

    return MemoryItem(
      id: rowId,
      text: row["text"],
      kind: kind,
      sensitivity: sensitivity,
      importance: importance,
      source: source,
      sessionId: row["session_id"],
      createdAt: row["created_at"]
    )
  }
}
