import ClawCore
import Foundation
import GRDB

public struct MemoryCommandStoreGRDB: MemoryCommandStore {
  private let writer: any DatabaseWriter
  private let afterClaimForTesting: @Sendable () throws -> Void

  public init(writer: any DatabaseWriter) {
    self.init(writer: writer, afterClaimForTesting: {})
  }

  init(
    writer: any DatabaseWriter,
    afterClaimForTesting: @Sendable @escaping () throws -> Void
  ) {
    self.writer = writer
    self.afterClaimForTesting = afterClaimForTesting
  }

  public func applyRemember(
    updateId: Int64,
    item: NewMemoryItem,
    now: Date
  ) throws -> MemoryCommandResult {
    try writer.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateId: updateId,
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
          argsRedacted: "/remember",  // the fact text may be sensitive; never audited verbatim
          decision: "remembered",
          sessionId: item.sessionId,
          ts: now
        )
      )

      return MemoryCommandResult(newlyClaimed: true, item: stored)
    }
  }

  public func applyForget(
    updateId: Int64,
    itemId: Int64,
    now: Date
  ) throws -> MemoryCommandResult {
    try writer.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateId: updateId,
        claimedAt: now
      )
      guard newlyClaimed else {
        return MemoryCommandResult(newlyClaimed: false, item: nil)
      }

      try afterClaimForTesting()

      try db.execute(sql: "DELETE FROM memory_items WHERE id = ?", arguments: [itemId])
      let didDelete = db.changesCount > 0

      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .owner,
          action: .memoryDelete,
          argsRedacted: "/memory delete",
          decision: didDelete ? "deleted" : "absent",
          sessionId: nil,
          ts: now
        )
      )

      return MemoryCommandResult(newlyClaimed: true, item: nil)
    }
  }
}
