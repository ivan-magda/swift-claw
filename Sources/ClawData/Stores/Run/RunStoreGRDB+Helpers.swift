import ClawCore
import Foundation
import GRDB

// MARK: - Cross-Store Run Helpers

extension RunStoreGRDB {
  /// When a run that belongs to a scheduled job reaches FAILED, `jobFailed` rides the SAME
  /// transaction as the state flip (house rule).
  ///
  /// No-op for job-less runs.
  static func appendJobFailedIfJobRun(_ db: Database, runID: Int64, now: Date) throws {
    let row = try Row.fetchOne(
      db,
      sql: "SELECT job_id, session_id FROM runs WHERE id = ?",
      arguments: [runID]
    )
    guard let row else {
      return
    }

    guard let jobID: Int64 = row["job_id"] else {
      return
    }

    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: .system,
        action: .jobFailed,
        decision: "job:\(jobID)",
        runID: runID,
        sessionID: row["session_id"],
        ts: now
      )
    )
  }

  /// True when the session already carries a non-terminal run (`RunState.liveStates`).
  ///
  /// The proactive-fire path checks this before resetting the shared context window: firing into a
  /// live run would advance the window out from under it, emptying its context on resume.
  static func hasLiveRun(_ db: Database, sessionID: Int64) throws -> Bool {
    // databaseQuestionMarks is GRDB's public helper — it renders "?,?,?" for the IN clause.
    let placeholders = databaseQuestionMarks(count: RunState.liveStates.count)
    var values: [DatabaseValueConvertible] = [sessionID]
    values.append(contentsOf: RunState.liveStates.map(\.rawValue))
    let found = try Int.fetchOne(
      db,
      sql: """
        SELECT 1 FROM runs
        WHERE session_id = ? AND state IN (\(placeholders))
        LIMIT 1
        """,
      arguments: StatementArguments(values)
    )
    return found != nil
  }

  static func supersedeRuns(_ db: Database, sessionID: Int64, now: Date) throws -> [Int64] {
    try terminateActiveRuns(db, sessionID: sessionID, reason: .superseded, now: now)
  }

  /// `/stop`'s plural arm: every live (PENDING, RUNNING, AWAITING_APPROVAL) run → CANCELLED.
  ///
  /// Mirrors `supersedeRuns` so `/stop` and `/new` share one definition of "active".
  static func cancelRuns(_ db: Database, sessionID: Int64, now: Date) throws -> [Int64] {
    try terminateActiveRuns(db, sessionID: sessionID, reason: .cancelled, now: now)
  }

  /// Terminates live runs while leaving learning settlement to the lane tail.
  ///
  /// A provider call still in flight may record usage after the run becomes terminal. Deferring
  /// settlement preserves that usage before the evidence is frozen.
  private static func terminateActiveRuns(
    _ db: Database,
    sessionID: Int64,
    reason: CancelReason,
    now: Date
  ) throws -> [Int64] {
    let placeholders = databaseQuestionMarks(count: RunState.liveStates.count)
    var values: [DatabaseValueConvertible] = [sessionID]
    values.append(contentsOf: RunState.liveStates.map(\.rawValue))
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT id FROM runs
        WHERE session_id = ? AND state IN (\(placeholders))
        ORDER BY id ASC
        """,
      arguments: StatementArguments(values)
    )

    var affected: [Int64] = []
    for row in rows {
      let runID: Int64 = row["id"]
      let transitioned = try transitionRun(
        db,
        runID: runID,
        event: reason.runEvent,
        now: now,
        terminal: .deferred(reason.terminalCause)
      )
      if transitioned != nil {
        affected.append(runID)
      }
    }

    return affected
  }

  // `public`: test fixtures outside this module (ClawGatewayTests, via plain `import ClawData`)
  // drive suspended-run fixtures through the real reducer instead of hand-rolling state.
  /// The one state-change seam, and therefore the one place a bound run's terminal receipt is
  /// written — inside the very transaction that wins the state.
  ///
  /// `terminal` is what that receipt records. Pass nil only for an event no terminal state is
  /// reachable from; should one be reached anyway, the run is damaged and records `unknown`
  /// rather than a cause guessed from `RunState`.
  public static func transitionRun(
    _ db: Database,
    runID: Int64,
    event: RunEvent,
    now: Date,
    policyVersion: String? = nil,
    terminal: TerminalDisposition?
  ) throws -> RunState? {
    guard
      let state = try currentRunState(db, runID: runID),
      let nextState = RunFSM.reduce(state: state, on: event)
    else {
      return nil
    }

    // The fingerprint rides the state flip in one UPDATE; a nil leaves the column
    // untouched so resolution/deny transitions never disturb the stamped value.
    if let policyVersion {
      try db.execute(
        sql: "UPDATE runs SET state = ?, updated_ts = ?, policy_version = ? WHERE id = ?",
        arguments: [nextState.rawValue, now, policyVersion, runID]
      )
    } else {
      try db.execute(
        sql: "UPDATE runs SET state = ?, updated_ts = ? WHERE id = ?",
        arguments: [nextState.rawValue, now, runID]
      )
    }

    if nextState.isTerminal {
      try ScheduledLearningStoreGRDB.recordTerminalReceipt(
        db,
        runID: runID,
        state: nextState,
        disposition: terminal ?? .deferred(.unknown),
        now: now
      )
    }

    return nextState
  }

  static func currentRunState(_ db: Database, runID: Int64) throws -> RunState? {
    let rawState = try String.fetchOne(
      db,
      sql: "SELECT state FROM runs WHERE id = ?",
      arguments: [runID]
    )

    guard let rawState else {
      return nil
    }

    return RunState(rawValue: rawState)
  }

  /// Inserts usage once per provider-call identity without suppressing unrelated constraint
  /// failures.
  ///
  /// The named `provider_call_id` conflict target ignores only an already-recorded call. Other
  /// uniqueness, NOT NULL, CHECK, and foreign-key failures still raise.
  static let insertUsageStatement = """
    INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens, completion_tokens,
      cost_usd, cost_source, is_estimated, ts, provider_call_id,
      learning_operation_id, learning_job_id)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(provider_call_id) DO NOTHING
    """

  /// Stores a provider usage row once per call identity within the caller's transaction.
  ///
  /// - Returns: Whether the row was newly stored; false means existing totals already count it.
  @discardableResult
  static func insertUsage(_ db: Database, _ usage: ProviderUsage) throws -> Bool {
    try db.execute(
      sql: insertUsageStatement,
      arguments: [
        usage.runID,
        usage.sessionID,
        usage.model,
        usage.promptTokens,
        usage.completionTokens,
        usage.costUSD,
        usage.costSource.rawValue,
        usage.isEstimated,
        usage.ts,
        usage.providerCallID.rawValue,
        usage.learningScope?.operationID.rawValue,
        usage.learningScope?.jobID,
      ]
    )
    return db.changesCount > 0
  }

  static func setSessionTainted(_ db: Database, sessionID: Int64, now: Date) throws {
    try db.execute(
      sql: "UPDATE sessions SET tainted = 1, updated_ts = ? WHERE id = ?",
      arguments: [now, sessionID]
    )
  }

  static func setSessionPrivateData(_ db: Database, sessionID: Int64, now: Date) throws {
    try db.execute(
      sql: "UPDATE sessions SET has_private_data = 1, updated_ts = ? WHERE id = ?",
      arguments: [now, sessionID]
    )
  }
}
