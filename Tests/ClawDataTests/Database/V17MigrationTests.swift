import ClawCore
import GRDB
import Testing

@testable import ClawData

@Suite struct V17MigrationTests {
  @Test func upgradePreservesLegacySubmissionsInInsertionOrderWithoutInventingPolicy() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrator.migrate(queue, upTo: "v16")
    try queue.write { db in
      try Self.insertLegacySubmission(db, id: "later-sorting-id", participant: 101)
      try Self.insertLegacySubmission(db, id: "earlier-sorting-id", participant: 202)
      try db.execute(
        sql: """
          UPDATE conference_submissions
          SET state = ?, pull_request_url = ?, branch = ?, commit_sha = ?, failure_reason = ?,
            notification_enqueued = 1, updated_ts = 2
          WHERE participant_user_id = 202
          """,
        arguments: [
          ConferenceSubmissionState.needsReview.rawValue,
          "https://github.com/fixture/challenge/pull/1", "conference/submission", "final-sha",
          "Publication needs review",
        ]
      )
    }
    let legacy = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM conference_submissions ORDER BY rowid")
    }

    // when
    try ClawDatabase.migrate(queue)

    // then
    try queue.read { db in
      let migrated = try Row.fetchAll(
        db,
        sql: """
          SELECT id, participant_user_id, case_id, case_json, answer, origin_json, state,
            coder_job_id, pull_request_url, branch, commit_sha, failure_reason,
            notification_enqueued, created_ts, updated_ts
          FROM conference_submissions ORDER BY queue_sequence
          """
      )
      #expect(migrated == legacy)
      #expect(
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM conference_submissions WHERE execution_policy_id IS NOT NULL"
        ) == 0
      )
      let columns = try db.columns(in: "conference_submissions")
      let sequence = try #require(
        columns.first { column in
          column.name == "queue_sequence"
        }
      )
      #expect(sequence.primaryKeyIndex == 1)
      #expect(sequence.type.uppercased() == "INTEGER")
    }
  }
}

// MARK: - Legacy Submissions

private extension V17MigrationTests {
  static func insertLegacySubmission(_ db: Database, id: String, participant: Int64) throws {
    try db.execute(
      sql: """
        INSERT INTO conference_submissions (
          id, participant_user_id, case_id, case_json, answer, origin_json, state,
          created_ts, updated_ts
        ) VALUES (?, ?, 'day-1', '{"case":"snapshot"}', ?, '{"origin":"snapshot"}', ?, 1, 1)
        """,
      arguments: [
        id, participant, "Answer from \(participant)", ConferenceSubmissionState.queued.rawValue,
      ]
    )
  }
}
