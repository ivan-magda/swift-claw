import ClawCore
import GRDB

public struct DraftIDStoreGRDB: DraftIDStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func nextID() throws(StoreError) -> Int64 {
    try database.writeMapping { db in
      try db.execute(sql: "INSERT INTO draft_ids DEFAULT VALUES")
      let id = db.lastInsertedRowID
      // AUTOINCREMENT retains the high-water mark in sqlite_sequence after deleting the row.
      try db.execute(sql: "DELETE FROM draft_ids")
      // Legacy proactive drafts use positive run IDs, including in concurrent session lanes.
      return -id
    }
  }
}
