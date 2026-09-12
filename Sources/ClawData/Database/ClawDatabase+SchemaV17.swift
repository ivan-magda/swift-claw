import ClawCore
import GRDB

extension ClawDatabase {
  static func addConferenceAdmissionIdentity(_ db: Database) throws {
    let states = ConferenceSubmissionState.allCases.map { state in
      "'\(state.rawValue)'"
    }.joined(separator: ", ")

    try db.execute(
      sql: """
        CREATE TABLE conference_submissions_ordered (
          queue_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          id TEXT UNIQUE NOT NULL,
          participant_user_id INTEGER NOT NULL,
          case_id TEXT NOT NULL,
          case_json TEXT NOT NULL,
          answer TEXT NOT NULL,
          origin_json TEXT NOT NULL,
          execution_policy_id TEXT,
          state TEXT NOT NULL CHECK (state IN (\(states))),
          coder_job_id TEXT REFERENCES coder_jobs(id),
          pull_request_url TEXT,
          branch TEXT,
          commit_sha TEXT,
          failure_reason TEXT,
          notification_enqueued INTEGER NOT NULL DEFAULT 0,
          created_ts INTEGER NOT NULL,
          updated_ts INTEGER NOT NULL,
          UNIQUE(participant_user_id, case_id)
        );
        INSERT INTO conference_submissions_ordered (
          queue_sequence, id, participant_user_id, case_id, case_json, answer, origin_json,
          state, coder_job_id, pull_request_url, branch, commit_sha, failure_reason,
          notification_enqueued, created_ts, updated_ts
        )
        SELECT rowid, id, participant_user_id, case_id, case_json, answer, origin_json,
          state, coder_job_id, pull_request_url, branch, commit_sha, failure_reason,
          notification_enqueued, created_ts, updated_ts
        FROM conference_submissions;
        DROP TABLE conference_submissions;
        ALTER TABLE conference_submissions_ordered RENAME TO conference_submissions;
        CREATE INDEX conference_submission_queue
          ON conference_submissions(state, queue_sequence);
        CREATE INDEX conference_submission_notifications
          ON conference_submissions(notification_enqueued, updated_ts, id);
        CREATE UNIQUE INDEX conference_submission_coder_job
          ON conference_submissions(coder_job_id)
          WHERE coder_job_id IS NOT NULL;
        """
    )
  }
}
