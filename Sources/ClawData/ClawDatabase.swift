import ClawCore
import Foundation
import GRDB

public enum ClawDatabase {
  public static func makeConfiguration(busyTimeout: TimeInterval = 5) -> Configuration {
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.busyMode = .timeout(busyTimeout)
    return config
  }

  public static func makePool(path: String) throws -> DatabasePool {
    do {
      return try DatabasePool(path: path, configuration: makeConfiguration())
    } catch {
      throw StoreError.openFailed("\(error)")
    }
  }

  /// Tests use an in-memory queue (WAL is unavailable in-memory).
  public static func makeInMemoryQueue() throws -> DatabaseQueue {
    try DatabaseQueue(configuration: makeConfiguration())
  }

  public static func migrate(_ writer: any DatabaseWriter) throws {
    do {
      try migrator.migrate(writer)
    } catch {
      throw StoreError.migrationFailed("\(error)")
    }
  }

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.create(table: "allowlist") { table in
        table.column("user_id", .integer).primaryKey()
        table.column("added_at", .datetime).notNull()
      }
      try db.create(table: "processed_updates") { table in
        table.column("update_id", .integer).primaryKey()
        table.column("claimed_at", .datetime).notNull()
      }
      try db.create(table: "update_cursor") { table in
        table.column("id", .integer).primaryKey()
        table.column("last_update_id", .integer).notNull()
      }
    }
    return migrator
  }
}
