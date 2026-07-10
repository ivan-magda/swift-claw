import ClawCore
import Foundation
import GRDB

// MARK: - Cross-Store Run Helpers

extension RunStoreGRDB {
  /// FR-C4/spec §14: when a run that belongs to a scheduled job reaches FAILED, `jobFailed`
  /// rides the SAME transaction as the state flip (house rule). No-op for job-less runs.
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

  static func supersedeRuns(_ db: Database, sessionId: Int64, now: Date) throws -> [Int64] {
    try terminateActiveRuns(db, sessionId: sessionId, event: .supersede, now: now)
  }

  /// `/stop`'s plural arm: every PENDING and RUNNING run for the session → CANCELLED. Mirrors
  /// `supersedeRuns` so `/stop` and `/new` share one definition of "active".
  static func cancelRuns(_ db: Database, sessionId: Int64, now: Date) throws -> [Int64] {
    try terminateActiveRuns(db, sessionId: sessionId, event: .cancel, now: now)
  }

  private static func terminateActiveRuns(
    _ db: Database,
    sessionId: Int64,
    event: RunEvent,
    now: Date
  ) throws -> [Int64] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT id FROM runs
        WHERE session_id = ? AND state IN (?, ?, ?)
        ORDER BY id ASC
        """,
      arguments: [
        sessionId,
        RunState.pending.rawValue,
        RunState.running.rawValue,
        RunState.awaitingApproval.rawValue,
      ]
    )

    var affected: [Int64] = []
    for row in rows {
      let runId: Int64 = row["id"]
      if try transitionRun(db, runId: runId, event: event, now: now) != nil {
        affected.append(runId)
      }
    }

    return affected
  }

  // `public`: Task 16 test fixtures outside this module (ClawGatewayTests, via plain `import
  // ClawData`) drive suspended-run fixtures through the real reducer instead of hand-rolling state.
  public static func transitionRun(
    _ db: Database,
    runId: Int64,
    event: RunEvent,
    now: Date,
    policyVersion: String? = nil
  ) throws -> RunState? {
    guard
      let state = try currentRunState(db, runId: runId),
      let nextState = RunFSM.reduce(state: state, on: event)
    else {
      return nil
    }

    // The fingerprint rides the state flip in one UPDATE (spec §3.2); a nil leaves the column
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

  static func insertUsage(_ db: Database, _ usage: ProviderUsage) throws {
    try db.execute(
      sql: """
        INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens, completion_tokens,
          cost_usd, cost_source, is_estimated, ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
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
      ]
    )
  }

  static func insertOutbox(
    _ db: Database,
    runId: Int64,
    chunk: OutboxChunk,
    now: Date
  ) throws -> Bool {
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
          payload_hash, approval_id, reply_markup, status, created_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?)
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
        now,
      ]
    )
    return db.changesCount > 0
  }

  /// A run's earlier commits may already occupy outbox steps (the §5.3 suspend prompt at step 0),
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
}
