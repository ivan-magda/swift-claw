import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V13MigrationTests {
  @Test func freshLatestMigrationInstallsOnlyTheLiveTrialIndexAndIsIdempotent() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)
    try ClawDatabase.migrate(queue)

    // then
    let indexes = try indexSQL(queue)
    #expect(indexes["idx_learning_trials_open_job"] == nil)
    let sql = try #require(indexes["idx_learning_trials_live_job"])
    #expect(sql.contains("UNIQUE INDEX"))
    #expect(sql.contains("state IN ('open', 'draining')"))
    #expect(try migrations(queue).last == "v13")
  }

  @Test func v13PreservesSeededV12LiveAndTerminalRows() throws {
    // given
    let queue = try v12Queue()
    try seedJob(queue, jobId: 1)
    try insertTrial(queue, jobId: 1, trialId: 1, state: .draining, candidateByte: "b")
    try insertTrial(queue, jobId: 1, trialId: 2, state: .promoted, candidateByte: "c")
    try insertTrial(queue, jobId: 1, trialId: 3, state: .fellBack, candidateByte: "d")

    // when
    try ClawDatabase.migrate(queue)

    // then
    let rows = try queue.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT trial_id, state FROM learning_trials ORDER BY trial_id"
      )
      .map { row in
        "\(row["trial_id"] as Int64):\(row["state"] as String)"
      }
    }
    #expect(rows == ["1:draining", "2:promoted", "3:fell_back"])
  }

  @Test(arguments: LiveTrialPair.allCases)
  func liveIndexRejectsEveryOpenAndDrainingPair(_ pair: LiveTrialPair) throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try seedJob(queue, jobId: 1)
    try insertTrial(
      queue,
      jobId: 1,
      trialId: 1,
      state: pair.first,
      candidateByte: "b"
    )

    // when / then — every ordered pair independently reaches the partial-index predicate.
    #expect {
      try insertTrialMapped(
        queue,
        jobId: 1,
        trialId: 2,
        state: pair.second,
        candidateByte: "c"
      )
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
    #expect(try trialCount(queue) == 1)
  }

  @Test func liveIndexAllowsEveryTerminalHistoryShape() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try seedJob(queue, jobId: 1)

    // when
    try insertTrial(queue, jobId: 1, trialId: 1, state: .open, candidateByte: "b")
    try insertTrial(queue, jobId: 1, trialId: 2, state: .promoted, candidateByte: "c")
    try insertTrial(queue, jobId: 1, trialId: 3, state: .fellBack, candidateByte: "d")
    try insertTrial(queue, jobId: 1, trialId: 4, state: .closed, candidateByte: "e")

    // then — widening the predicate to any terminal state rejects one of these rows.
    #expect(try trialCount(queue) == 4)
  }

  @Test func conflictingV12UpgradeRollsBackAndRetriesAfterRepair() throws {
    // given
    let queue = try v12Queue()
    try seedJob(queue, jobId: 1)
    try insertTrial(queue, jobId: 1, trialId: 1, state: .open, candidateByte: "b")
    try insertTrial(queue, jobId: 1, trialId: 2, state: .draining, candidateByte: "c")

    // when
    #expect {
      try ClawDatabase.migrate(queue)
    } throws: { error in
      guard case StoreError.migrationFailed = error else {
        return false
      }
      return true
    }

    // then
    var indexes = try indexSQL(queue)
    #expect(indexes["idx_learning_trials_open_job"] != nil)
    #expect(indexes["idx_learning_trials_live_job"] == nil)
    #expect(try migrations(queue).contains("v13") == false)
    #expect(try trialCount(queue) == 2)

    try queue.write { db in
      try db.execute(
        sql: "UPDATE learning_trials SET state = ? WHERE trial_id = 2",
        arguments: [LearningTrialState.closed.rawValue]
      )
    }
    try ClawDatabase.migrate(queue)
    indexes = try indexSQL(queue)
    #expect(indexes["idx_learning_trials_open_job"] == nil)
    #expect(indexes["idx_learning_trials_live_job"] != nil)
    #expect(try migrations(queue).last == "v13")
  }
}

enum LiveTrialPair: CaseIterable {
  case openOpen
  case openDraining
  case drainingOpen
  case drainingDraining

  var first: LearningTrialState {
    switch self {
    case .openOpen, .openDraining:
      .open
    case .drainingOpen, .drainingDraining:
      .draining
    }
  }

  var second: LearningTrialState {
    switch self {
    case .openOpen, .drainingOpen:
      .open
    case .openDraining, .drainingDraining:
      .draining
    }
  }
}

// MARK: - Schema Fixtures

private func v12Queue() throws -> DatabaseQueue {
  let queue = try ClawDatabase.makeInMemoryQueue()
  try ClawDatabase.migrator.migrate(queue, upTo: "v12")
  return queue
}

private func seedJob(_ queue: DatabaseQueue, jobId: Int64) throws {
  let base = String(repeating: "a", count: 64)
  try queue.write { db in
    try db.execute(
      sql: """
        INSERT INTO scheduled_jobs(id, owner_chat_id, label, prompt, recurrence, timezone,
          next_occurrence, last_fired_at, status, session_id, created_ts, updated_ts)
        VALUES (?, 1, 'job', 'prompt', '{}', 'UTC', NULL, NULL, 'active', NULL, 1, 1)
        """,
      arguments: [jobId]
    )
    try db.execute(
      sql: """
        INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source, created_at)
        VALUES (?, ?, 1, X'00', 'canonical_empty', 1)
        """,
      arguments: [jobId, base]
    )
    try db.execute(
      sql: """
        INSERT INTO job_learning_state(job_id, learning_epoch, stable_lesson_set_digest,
          stable_revision, open_trial_id, feedback_revision, armed_at)
        VALUES (?, 1, ?, 0, NULL, 0, 1)
        """,
      arguments: [jobId, base]
    )
  }
}

private func insertTrial(
  _ queue: DatabaseQueue,
  jobId: Int64,
  trialId: Int64,
  state: LearningTrialState,
  candidateByte: String
) throws {
  try queue.write { db in
    try insertTrial(db, jobId: jobId, trialId: trialId, state: state, candidateByte: candidateByte)
  }
}

private func insertTrialMapped(
  _ queue: DatabaseQueue,
  jobId: Int64,
  trialId: Int64,
  state: LearningTrialState,
  candidateByte: String
) throws(StoreError) {
  try MappedDatabase(writer: queue).writeMapping { db in
    try insertTrial(db, jobId: jobId, trialId: trialId, state: state, candidateByte: candidateByte)
  }
}

private func insertTrial(
  _ db: Database,
  jobId: Int64,
  trialId: Int64,
  state: LearningTrialState,
  candidateByte: String
) throws {
  let base = String(repeating: "a", count: 64)
  let candidate = String(repeating: candidateByte, count: 64)
  try db.execute(
    sql: """
      INSERT INTO learning_candidates(candidate_digest, job_id, learning_epoch,
        replacement_digest, base_digest, base_revision, frozen_feedback_revision, origin,
        source_manifest, predecessor_digest, algorithm, created_at)
      VALUES (?, ?, 1, ?, ?, 0, 0, 'reflection', '{}', NULL, ?, 1)
      """,
    arguments: [candidate, jobId, base, base, LearningAlgorithm.v1.rawValue]
  )
  try db.execute(
    sql: """
      INSERT INTO learning_trials(trial_id, job_id, learning_epoch, base_digest,
        candidate_digest, generation, admitted_at, assignment_deadline, decision_deadline,
        max_assignments, consumed_assignments, cohort_cutoff, state, close_reason, algorithm)
      VALUES (?, ?, 1, ?, ?, ?, 1, 2, 3, 3, 0, 1, ?, NULL, ?)
      """,
    arguments: [
      trialId,
      jobId,
      base,
      candidate,
      Int(trialId),
      state.rawValue,
      LearningAlgorithm.v1.rawValue,
    ]
  )
}

private func indexSQL(_ queue: DatabaseQueue) throws -> [String: String] {
  try queue.read { db in
    let rows = try Row.fetchAll(
      db,
      sql:
        "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'learning_trials'"
    )
    return Dictionary(
      uniqueKeysWithValues: rows.compactMap { row in
        guard let name: String = row["name"], let sql: String = row["sql"] else {
          return nil
        }
        return (name, sql)
      }
    )
  }
}

private func migrations(_ queue: DatabaseQueue) throws -> [String] {
  try queue.read { db in
    try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
  }
}

private func trialCount(_ queue: DatabaseQueue) throws -> Int {
  try queue.read { db in
    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM learning_trials") ?? -1
  }
}
