import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ClawDatabaseTests {
  @Test func migrationCreatesExpectedTables() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    let tables = try queue.read { db -> Set<String> in
      let names = try String.fetchAll(
        db,
        sql:
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'"
      )
      return Set(names)
    }
    #expect(tables.isSuperset(of: ["allowlist", "processed_updates", "update_cursor"]))
  }

  @Test func foreignKeysAndBusyTimeoutAreSet() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // then
    let foreignKeys = try #require(
      try queue.read { db in
        try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
      }
    )
    #expect(foreignKeys == 1)
    let busyTimeout = try #require(
      try queue.read { db in
        try Int.fetchOne(db, sql: "PRAGMA busy_timeout")
      }
    )
    #expect(busyTimeout >= 5000)
  }

  /// `v11`/`v12` shipped in a release, so the learning tables were renumbered above them rather
  /// than reusing those identifiers. A database already at `v12` must therefore reach the learning
  /// schema with its Coder rows untouched — reassigning either identifier would silently skip the
  /// migration a released database has already recorded.
  @Test func releasedCoderDatabaseUpgradesIntoLearningWithItsJobsIntact() throws {
    // given
    let fixture = try CoderStoreFixture(schemaVersion: "v12")
    let jobID = UUID()
    _ = try fixture.admit(id: jobID, limit: 1)
    #expect(try Self.tables(fixture.queue).contains("job_learning_state") == false)

    // when
    try ClawDatabase.migrate(fixture.queue)

    // then
    #expect(try fixture.store.job(id: jobID) != nil)
    #expect(
      try Self.tables(fixture.queue)
        .isSuperset(of: ["coder_jobs", "job_learning_state", "learning_trials"])
    )
  }

  /// The two features' tables arrive in release order, not alphabetical or authoring order: the
  /// Coder schema is complete at `v12` and no learning table exists before `v13`.
  @Test func coderSchemaLandsBeforeAnyLearningTable() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrator.migrate(queue, upTo: "v12")

    // then
    let atReleasedCoder = try Self.tables(queue)
    #expect(atReleasedCoder.contains("coder_jobs"))
    #expect(atReleasedCoder.filter { $0.hasPrefix("learning_") }.isEmpty)
    try ClawDatabase.migrate(queue)
    #expect(try Self.tables(queue).contains("learning_operations"))
  }

  @Test func migrationIsIdempotent() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    try ClawDatabase.migrate(queue)
  }
}

// MARK: - Schema Introspection

private extension ClawDatabaseTests {
  static func tables(_ queue: DatabaseQueue) throws -> Set<String> {
    try queue.read { db in
      Set(
        try String.fetchAll(
          db,
          sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """
        )
      )
    }
  }
}
