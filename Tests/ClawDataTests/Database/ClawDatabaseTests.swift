import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct ClawDatabaseTests {
  @Test
  func migrationCreatesExpectedTables() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    let tables = try queue.read { db -> Set<String> in
      let names = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master WHERE type='table' \
          AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
          """
      )
      return Set(names)
    }
    #expect(tables.isSuperset(of: ["allowlist", "processed_updates", "update_cursor"]))
  }

  @Test
  func foreignKeysAndBusyTimeoutAreSet() throws {
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
  @Test
  func releasedCoderDatabaseUpgradesIntoLearningWithItsJobsIntact() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrator.migrate(queue, upTo: "v12")
    let jobID = UUID()
    try Self.seedReleasedCoderJob(queue, id: jobID)
    #expect(try Self.tables(queue).contains("job_learning_state") == false)

    // when
    try ClawDatabase.migrate(queue)

    // then
    #expect(try CoderJobStoreGRDB(writer: queue).job(id: jobID) != nil)
    #expect(
      try Self.tables(queue).isSuperset(of: [
        "coder_jobs",
        "job_learning_state",
        "learning_trials",
      ])
    )
  }

  /// The two features' tables arrive in release order, not alphabetical or authoring order: the
  /// Coder schema is complete at `v12` and no learning table exists before `v13`.
  @Test
  func coderSchemaLandsBeforeAnyLearningTable() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrator.migrate(queue, upTo: "v12")

    // then
    let atReleasedCoder = try Self.tables(queue)
    #expect(atReleasedCoder.contains("coder_jobs"))
    #expect(
      !atReleasedCoder.contains {
        $0.hasPrefix("learning_")
      }
    )
    try ClawDatabase.migrate(queue)
    #expect(try Self.tables(queue).contains("learning_operations"))
  }

  @Test
  func migrationIsIdempotent() throws {
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
  /// Released-schema fixtures must not depend on today's store column lists.
  static func seedReleasedCoderJob(_ queue: DatabaseQueue, id: UUID) throws {
    let prepared = CoderStoreFixture.localRequest(
      checkout: "/fixture/repository",
      common: "/fixture/repository/.git"
    )
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(id, session_key, created_ts, updated_ts)
          VALUES (1, 'tg:dm:7', ?, ?)
          """,
        arguments: [Date(), Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO runs(id, session_id, state, created_ts, updated_ts)
          VALUES (1, 1, ?, ?, ?)
          """,
        arguments: [RunState.running.rawValue, Date(), Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO approvals(id, run_id, session_id, state, tool, canonical_args,
            canonical_target, args_hash, policy_version, owner_user_id, nonce,
            observation_message_id, tool_call_id, reason, created_ts, expires_ts)
          VALUES (1, 1, 1, ?, 'coder', '{}', '', '', '', 7, 'legacy', 1, 't', '', ?, ?)
          """,
        arguments: [ApprovalState.approved.rawValue, Date(), Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO coder_jobs(id, origin_run_id, origin_session_id, requester_user_id,
            chat_id, tool_call_id, approval_id, prepared_json, state, slot_reserved,
            process_ownership, created_ts, updated_ts)
          VALUES (?, 1, 1, 7, 7, 't', 1, ?, ?, 1, ?, 1, 1)
          """,
        arguments: [
          id.uuidString,
          try CoderJobRecord.encodeJSON(prepared),
          CoderJobState.admitted.rawValue,
          CoderProcessOwnership.none.rawValue,
        ]
      )
    }
  }

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
