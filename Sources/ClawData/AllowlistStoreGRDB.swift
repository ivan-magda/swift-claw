import ClawCore
import Foundation
import GRDB

public struct AllowlistStoreGRDB: AllowlistStore {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func seedAllowlist(userIds: [Int64]) throws {
    try writer.write { db in
      for userId in userIds {
        try db.execute(
          sql: "INSERT OR IGNORE INTO allowlist(user_id, added_at) VALUES (?, ?)",
          arguments: [userId, Date()]
        )
      }
    }
  }

  public func allowlistContains(userId: Int64) throws -> Bool {
    try writer.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS(SELECT 1 FROM allowlist WHERE user_id = ?)",
        arguments: [userId]
      ) ?? false
    }
  }

  public func allowlistCount() throws -> Int {
    try writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM allowlist") ?? 0
    }
  }
}
