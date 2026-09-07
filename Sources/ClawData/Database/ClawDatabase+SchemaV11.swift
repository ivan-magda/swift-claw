import ClawCore
import GRDB

extension ClawDatabase {
  static func createCoderJobs(_ db: Database) throws {
    let states: [CoderJobState] = [
      .admitted, .running, .stopping, .succeeded, .failed, .cancelled, .timedOut, .interrupted,
    ]
    let ownerships: [CoderProcessOwnership] = [.none, .launching, .owned, .stopped, .unresolved]
    let stateCheck = states.map {
      "'\($0.rawValue)'"
    }.joined(separator: ", ")
    let ownershipCheck = ownerships.map {
      "'\($0.rawValue)'"
    }.joined(separator: ", ")
    try db.execute(
      sql: """
        CREATE TABLE coder_jobs (
          id TEXT PRIMARY KEY NOT NULL,
          origin_run_id INTEGER NOT NULL REFERENCES runs(id),
          origin_session_id INTEGER NOT NULL REFERENCES sessions(id),
          requester_user_id INTEGER NOT NULL,
          chat_id INTEGER NOT NULL,
          tool_call_id TEXT NOT NULL,
          approval_id INTEGER NOT NULL REFERENCES approvals(id),
          prepared_json TEXT NOT NULL,
          state TEXT NOT NULL CHECK (state IN (\(stateCheck))),
          slot_reserved INTEGER NOT NULL CHECK (slot_reserved IN (0, 1)),
          checkout_path TEXT,
          common_git_directory TEXT,
          process_ownership TEXT NOT NULL CHECK (process_ownership IN (\(ownershipCheck))),
          process_receipt_json TEXT,
          result_json TEXT,
          created_ts INTEGER NOT NULL,
          updated_ts INTEGER NOT NULL,
          UNIQUE (origin_run_id, tool_call_id)
        );
        CREATE INDEX coder_reserved ON coder_jobs(slot_reserved);
        """
    )
  }
}
