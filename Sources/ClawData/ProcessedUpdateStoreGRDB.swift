import ClawCore
import Foundation
import GRDB

public struct ProcessedUpdateStoreGRDB: ProcessedUpdateStore {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func claimUpdate(updateId: Int64) throws -> Bool {
    try writer.write { db in
      try Self.claimUpdate(db: db, updateId: updateId, claimedAt: Date())
    }
  }

  static func claimUpdate(db: Database, updateId: Int64, claimedAt: Date) throws -> Bool {
    try db.execute(
      sql: "INSERT OR IGNORE INTO processed_updates(update_id, claimed_at) VALUES (?, ?)",
      arguments: [updateId, claimedAt]
    )
    return db.changesCount > 0
  }
}
