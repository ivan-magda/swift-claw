import ClawCore
import GRDB

extension ClawDatabase {
  static func createConferenceSubmissions(_ db: Database) throws {
    let states = ConferenceSubmissionState.allCases.map { "'\($0.rawValue)'" }
      .joined(separator: ", ")

    try db.execute(
      sql: """
        CREATE TABLE conference_submissions (
          id TEXT PRIMARY KEY NOT NULL,
          participant_user_id INTEGER NOT NULL,
          case_id TEXT NOT NULL,
          case_json TEXT NOT NULL,
          answer TEXT NOT NULL,
          origin_json TEXT NOT NULL,
          state TEXT NOT NULL CHECK (state IN (\(states))),
          coder_job_id TEXT REFERENCES coder_jobs(id),
          pull_request_url TEXT,
          branch TEXT,
          commit_sha TEXT,
          failure_reason TEXT,
          created_ts INTEGER NOT NULL,
          updated_ts INTEGER NOT NULL,
          UNIQUE(participant_user_id, case_id)
        );
        CREATE INDEX conference_submission_queue
          ON conference_submissions(state, created_ts, id);
        CREATE UNIQUE INDEX conference_submission_coder_job
          ON conference_submissions(coder_job_id)
          WHERE coder_job_id IS NOT NULL;
        """
    )
  }
}
