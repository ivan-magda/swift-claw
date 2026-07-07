import ClawCore
import GRDB

/// Single-row (id = 0) cursor holding the last confirmed update id.
public struct UpdateCursorStoreGRDB: UpdateCursorStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func loadCursor() throws -> Int64? {
    try database.readMapping { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT last_update_id FROM update_cursor WHERE id = 0"
      )
    }
  }

  public func advanceCursor(to updateId: Int64) throws {
    try database.writeMapping { db in
      try db.execute(
        sql: """
          INSERT INTO update_cursor(id, last_update_id) VALUES (0, ?)
          ON CONFLICT(id) DO UPDATE SET
          last_update_id = MAX(last_update_id, excluded.last_update_id)
          """,
        arguments: [updateId]
      )
    }
  }
}
