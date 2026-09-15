import ClawCore
import Foundation
import GRDB

public struct ProcessedUpdateStoreGRDB: ProcessedUpdateStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) { database = MappedDatabase(writer: writer) }

  public func claimUpdate(updateID: Int64) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      try Self.claimUpdate(db: db, updateID: updateID, claimedAt: Date())
    }
  }

  static func claimUpdate(db: Database, updateID: Int64, claimedAt: Date) throws -> Bool {
    try db.execute(
      sql: "INSERT OR IGNORE INTO processed_updates(update_id, claimed_at) VALUES (?, ?)",
      arguments: [updateID, claimedAt]
    )
    return db.changesCount > 0
  }
}
