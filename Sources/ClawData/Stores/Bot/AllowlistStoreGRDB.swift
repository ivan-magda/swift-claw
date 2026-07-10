import ClawCore
import Foundation
import GRDB

public struct AllowlistStoreGRDB: AllowlistStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func seedAllowlist(userIds: [Int64]) throws(StoreError) {
    try database.writeMapping { db in
      for userId in userIds {
        try db.execute(
          sql: "INSERT OR IGNORE INTO allowlist(user_id, added_at) VALUES (?, ?)",
          arguments: [userId, Date()]
        )
      }
    }
  }

  public func allowlistContains(userId: Int64) throws(StoreError) -> Bool {
    try database.readMapping { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS(SELECT 1 FROM allowlist WHERE user_id = ?)",
        arguments: [userId]
      ) ?? false
    }
  }

  public func allowlistCount() throws(StoreError) -> Int {
    try database.readMapping { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM allowlist") ?? 0
    }
  }
}
