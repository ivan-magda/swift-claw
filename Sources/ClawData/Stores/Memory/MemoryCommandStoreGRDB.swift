import ClawCore
import Foundation
import GRDB

public struct MemoryCommandStoreGRDB: MemoryCommandStore {
  private let database: MappedDatabase
  private let afterClaimForTesting: @Sendable () throws -> Void

  public init(writer: any DatabaseWriter) { self.init(writer: writer) {} }

  init(writer: any DatabaseWriter, afterClaimForTesting: @Sendable @escaping () throws -> Void) {
    database = MappedDatabase(writer: writer)
    self.afterClaimForTesting = afterClaimForTesting
  }

  public func applyRemember(
    updateID: Int64,
    item: NewMemoryItem,
    now: Date
  ) throws(StoreError) -> MemoryCommandResult {
    try database.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateID: updateID,
        claimedAt: now
      )
      guard newlyClaimed else {
        return MemoryCommandResult(newlyClaimed: false, item: nil)
      }

      try afterClaimForTesting()

      let stored = try MemoryStoreGRDB.insertItem(db, item: item, now: now)

      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .owner,
          action: .memoryWrite,
          argsRedacted: "/remember",
          decision: "remembered",
          sessionID: item.sessionID,
          ts: now
        )
      )

      return MemoryCommandResult(newlyClaimed: true, item: stored)
    }
  }

  public func applyForget(
    updateID: Int64,
    itemID: Int64,
    now: Date
  ) throws(StoreError) -> MemoryCommandResult {
    try database.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateID: updateID,
        claimedAt: now
      )
      guard newlyClaimed else {
        return MemoryCommandResult(newlyClaimed: false, item: nil)
      }

      try afterClaimForTesting()

      try db.execute(sql: "DELETE FROM memory_items WHERE id = ?", arguments: [itemID])
      let didDelete = db.changesCount > 0

      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .owner,
          action: .memoryDelete,
          argsRedacted: "/memory delete",
          decision: didDelete ? "deleted" : "absent",
          sessionID: nil,
          ts: now
        )
      )

      return MemoryCommandResult(newlyClaimed: true, item: nil)
    }
  }
}
