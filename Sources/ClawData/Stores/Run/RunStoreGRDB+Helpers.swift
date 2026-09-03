import ClawCore
import Foundation
import GRDB

// MARK: - Cross-Store Run Helpers

extension RunStoreGRDB {
  /// When a run that belongs to a scheduled job reaches FAILED, `jobFailed` rides the SAME
  /// transaction as the state flip (house rule). No-op for job-less runs.
  static func appendJobFailedIfJobRun(_ db: Database, runId: Int64, now: Date) throws {
    let row = try Row.fetchOne(
      db,
      sql: "SELECT job_id, session_id FROM runs WHERE id = ?",
      arguments: [runId]
    )
    guard let row else {
      return
    }

    guard let jobId: Int64 = row["job_id"] else {
      return
    }

    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: .system,
        action: .jobFailed,
        decision: "job:\(jobId)",
        runId: runId,
        sessionId: row["session_id"],
        ts: now
      )
    )
  }

  static func fetchActiveRunId(_ db: Database, sessionId: Int64) throws -> Int64? {
    try Int64.fetchOne(
      db,
      sql: """
        SELECT id FROM runs
        WHERE session_id = ? AND state IN (?, ?)
        ORDER BY id DESC
        LIMIT 1
        """,
      arguments: [
        sessionId,
        RunState.running.rawValue,
        RunState.awaitingApproval.rawValue,
      ]
    )
  }

  /// True when the session already carries a non-terminal run (`RunState.liveStates`). The
  /// proactive-fire path checks this before resetting the shared context window: firing into a
  /// live run would advance the window out from under it, emptying its context on resume.
  static func hasLiveRun(_ db: Database, sessionId: Int64) throws -> Bool {
    // databaseQuestionMarks is GRDB's public helper — it renders "?,?,?" for the IN clause.
    let placeholders = databaseQuestionMarks(count: RunState.liveStates.count)
    var values: [DatabaseValueConvertible] = [sessionId]
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

  static func supersedeRuns(_ db: Database, sessionId: Int64, now: Date) throws -> [Int64] {
    try terminateActiveRuns(db, sessionId: sessionId, reason: .superseded, now: now)
  }

  /// `/stop`'s plural arm: every PENDING and RUNNING run for the session → CANCELLED. Mirrors
  /// `supersedeRuns` so `/stop` and `/new` share one definition of "active".
  static func cancelRuns(_ db: Database, sessionId: Int64, now: Date) throws -> [Int64] {
    try terminateActiveRuns(db, sessionId: sessionId, reason: .cancelled, now: now)
  }

  /// Settlement is deliberately deferred on both arms: a provider call still in flight when the
  /// command wins records its usage after the run is terminal, so freezing the evidence here would
  /// either lose that usage or admit it against a frozen receipt. The lane tail settles instead.
  private static func terminateActiveRuns(
    _ db: Database,
    sessionId: Int64,
    reason: CancelReason,
    now: Date
  ) throws -> [Int64] {
    let placeholders = databaseQuestionMarks(count: RunState.liveStates.count)
    var values: [DatabaseValueConvertible] = [sessionId]
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
      let runId: Int64 = row["id"]
      let transitioned = try transitionRun(
        db,
        runId: runId,
        event: reason.runEvent,
        now: now,
        terminal: .deferred(reason.terminalCause)
      )
      if transitioned != nil {
        affected.append(runId)
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
    runId: Int64,
    event: RunEvent,
    now: Date,
    policyVersion: String? = nil,
    terminal: TerminalDisposition?
  ) throws -> RunState? {
    guard
      let state = try currentRunState(db, runId: runId),
      let nextState = RunFSM.reduce(state: state, on: event)
    else {
      return nil
    }

    // The fingerprint rides the state flip in one UPDATE; a nil leaves the column
    // untouched so resolution/deny transitions never disturb the stamped value.
    if let policyVersion {
      try db.execute(
        sql: "UPDATE runs SET state = ?, updated_ts = ?, policy_version = ? WHERE id = ?",
        arguments: [nextState.rawValue, now, policyVersion, runId]
      )
    } else {
      try db.execute(
        sql: "UPDATE runs SET state = ?, updated_ts = ? WHERE id = ?",
        arguments: [nextState.rawValue, now, runId]
      )
    }

    if nextState.isTerminal {
      try ScheduledLearningStoreGRDB.recordTerminalReceipt(
        db,
        runId: runId,
        state: nextState,
        disposition: terminal ?? .deferred(.unknown),
        now: now
      )
    }

    return nextState
  }

  static func currentRunState(_ db: Database, runId: Int64) throws -> RunState? {
    let rawState = try String.fetchOne(
      db,
      sql: "SELECT state FROM runs WHERE id = ?",
      arguments: [runId]
    )

    guard let rawState else {
      return nil
    }

    return RunState(rawValue: rawState)
  }

  /// The conflict target is named rather than left bare: an untargeted `DO NOTHING` silences every
  /// uniqueness failure the row could hit, so a genuinely corrupt insert would return the same
  /// "wrote nothing" the caller reads as a harmless replay. Naming `provider_call_id` silences
  /// re-presentation of an already-recorded call and nothing else — a NOT NULL, CHECK, or foreign
  /// key failure still raises.
  static let insertUsageStatement = """
    INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens, completion_tokens,
      cost_usd, cost_source, is_estimated, ts, provider_call_id,
      learning_operation_id, learning_job_id)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(provider_call_id) DO NOTHING
    """

  /// - Returns: whether this call's row was newly stored. `false` means the identity was already
  ///   recorded, so every total derived from these rows already counts it.
  @discardableResult
  static func insertUsage(_ db: Database, _ usage: ProviderUsage) throws -> Bool {
    try db.execute(
      sql: insertUsageStatement,
      arguments: [
        usage.runId,
        usage.sessionId,
        usage.model,
        usage.promptTokens,
        usage.completionTokens,
        usage.costUSD,
        usage.costSource.rawValue,
        usage.isEstimated,
        usage.ts,
        usage.providerCallID.rawValue,
        usage.learningScope?.operationId.rawValue,
        usage.learningScope?.jobId,
      ]
    )
    return db.changesCount > 0
  }

  static func insertOutbox(
    _ db: Database,
    runId: Int64,
    chunk: OutboxChunk,
    now: Date
  ) throws -> Bool {
    let target = try outboxTarget(db, runId: runId, chatId: chunk.chatId)
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
          payload_hash, approval_id, reply_markup, message_thread_id, reply_to_message_id,
          status, created_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?)
        """,
      arguments: [
        runId,
        chunk.stepIndex,
        chunk.chatId,
        OutboxDedupKey.make(runId: runId, stepIndex: chunk.stepIndex),
        chunk.payload,
        chunk.payloadHash,
        chunk.approvalId,
        chunk.replyMarkup,
        target.messageThreadId,
        target.replyToMessageId,
        now,
      ]
    )
    return db.changesCount > 0
  }

  /// Where a run's answer belongs, read from the run itself rather than passed in by whoever
  /// enqueued the chunk: every producer (a finished turn, an approval prompt, a boot notice) then
  /// lands in the same topic, and a row committed before a restart still knows its topic after one.
  /// A direct-mode run resolves to the plain chat target, unchanged from before group mode.
  static func outboxTarget(
    _ db: Database,
    runId: Int64,
    chatId: Int64
  ) throws -> DeliveryTarget {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT sessions.session_key AS session_key,
          runs.trigger_telegram_message_id AS trigger_telegram_message_id
        FROM runs JOIN sessions ON sessions.id = runs.session_id
        WHERE runs.id = ?
        """,
      arguments: [runId]
    )
    guard let row, SessionKey.mode(from: row["session_key"]) == .group else {
      return .chat(chatId)
    }
    return DeliveryTarget(
      chatId: chatId,
      messageThreadId: SessionKey.threadId(from: row["session_key"]),
      replyToMessageId: row["trigger_telegram_message_id"]
    )
  }

  /// A run's earlier commits may already occupy outbox steps (the suspend prompt at step 0),
  /// and `dedup_key` is `runId:stepIndex` under INSERT OR IGNORE — a colliding chunk would be
  /// dropped SILENTLY. Every later enqueue therefore extends the run's delivery sequence from
  /// this base (0 for an ordinary run, so the plain path is untouched).
  static func nextOutboxStepBase(_ db: Database, runId: Int64) throws -> Int {
    try Int.fetchOne(
      db,
      sql: "SELECT COALESCE(MAX(step_index) + 1, 0) FROM outbound_deliveries WHERE run_id = ?",
      arguments: [runId]
    ) ?? 0
  }

  /// The same chunk re-based into the run's delivery sequence (identity when `base == 0`).
  static func shiftedChunk(_ chunk: OutboxChunk, by base: Int) -> OutboxChunk {
    guard base > 0 else {
      return chunk
    }
    return OutboxChunk(
      stepIndex: chunk.stepIndex + base,
      chatId: chunk.chatId,
      payload: chunk.payload,
      payloadHash: chunk.payloadHash,
      approvalId: chunk.approvalId,
      replyMarkup: chunk.replyMarkup
    )
  }

  static func setSessionTainted(_ db: Database, sessionId: Int64, now: Date) throws {
    try db.execute(
      sql: "UPDATE sessions SET tainted = 1, updated_ts = ? WHERE id = ?",
      arguments: [now, sessionId]
    )
  }

  static func setSessionPrivateData(_ db: Database, sessionId: Int64, now: Date) throws {
    try db.execute(
      sql: "UPDATE sessions SET has_private_data = 1, updated_ts = ? WHERE id = ?",
      arguments: [now, sessionId]
    )
  }
}
