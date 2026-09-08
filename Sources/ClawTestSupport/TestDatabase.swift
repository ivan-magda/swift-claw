import ClawData
import GRDB

public enum TestDatabase {
  /// Returns an independent, empty database with the current production schema.
  public static func make() throws -> DatabaseQueue {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try emptyDatabase.get().backup(to: queue)
    return queue
  }
}

// MARK: - Migrated Template

private extension TestDatabase {
  static let emptyDatabase: Result<DatabaseQueue, any Error> = Result {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return queue
  }
}
