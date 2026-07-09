import ClawCore
import Foundation
import GRDB

public struct RunStoreGRDB: RunStore {
  private let database: MappedDatabase
  private let suspendCommitFault: @Sendable () throws -> Void

  public init(writer: any DatabaseWriter) {
    self.init(writer: writer, suspendCommitFault: {})
  }

  init(
    writer: any DatabaseWriter,
    suspendCommitFault: @escaping @Sendable () throws -> Void
  ) {
    database = MappedDatabase(writer: writer)
    self.suspendCommitFault = suspendCommitFault
  }

  public func pickUp(runId: Int64, policyVersion: String?, now: Date) throws -> RunOrigin? {
    try database.writeMapping { db in
      guard
        try Self.transitionRun(
          db,
          runId: runId,
          event: .pickUp,
          now: now,
          policyVersion: policyVersion
        ) != nil
      else {
        return nil
      }

      let rawOrigin = try String.fetchOne(
        db,
        sql: "SELECT origin FROM runs WHERE id = ?",
        arguments: [runId]
      )
      // Fail closed on a corrupted origin (same rule as decodeItem): a mislabeled origin would
      // silently re-route budget pools and delivery policy. The throw rolls back the pickUp
      // transition, so the run stays PENDING for the boot sweep.
      guard let rawOrigin, let origin = RunOrigin(rawValue: rawOrigin) else {
        throw StoreError.unexpected("runs row \(runId) has an unrecognized origin")
      }

      return origin
    }
  }

  public func cancelActiveRun(
    sessionId: Int64,
    reason: CancelReason,
    now: Date
  ) throws -> Int64? {
    try database.writeMapping { db in
      guard let runId = try Self.fetchActiveRunId(db, sessionId: sessionId) else {
        return nil
      }

      let event: RunEvent =
        switch reason {
        case .cancelled: .cancel
        case .superseded: .supersede
        }
      guard try Self.transitionRun(db, runId: runId, event: event, now: now) != nil else {
        return nil
      }

      return runId
    }
  }

  public func supersedeSessionRuns(sessionId: Int64, now: Date) throws -> [Int64] {
    try database.writeMapping { db in
      try Self.supersedeRuns(db, sessionId: sessionId, now: now)
    }
  }

  public func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws -> RunCommitResult {
    try database.writeMapping { db in
      guard let currentState = try Self.currentRunState(db, runId: turn.runId) else {
        return .ignored
      }

      guard currentState == .running else {
        if turn.setTainted, currentState == .cancelled {
          try Self.setSessionTainted(db, sessionId: turn.sessionId, now: now)
        }
        return try Self.recordTerminalUsageIfNeeded(
          db,
          usage: turn.usage,
          state: currentState,
          now: now
        )
      }

      let nextState = try Self.transitionRun(
        db,
        runId: turn.runId,
        event: .complete,
        now: now
      )
      guard let nextState else {
        return .ignored
      }

      for exchange in turn.exchanges {
        try Self.insertExchangeRows(
          db,
          sessionId: turn.sessionId,
          runId: turn.runId,
          exchange: exchange,
          now: now
        )
      }

      let usage = turn.usage
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, prompt_tokens, completion_tokens)
          VALUES (?, ?, 'assistant', ?, 'trusted', ?, ?, ?)
          """,
        arguments: [
          turn.sessionId,
          turn.runId,
          turn.content,
          now,
          usage.promptTokens,
          usage.completionTokens,
        ]
      )
      try db.execute(
        sql:
          "UPDATE runs SET state = ?, updated_ts = ?, input_tokens = ?, output_tokens = ?, cost_usd = ? WHERE id = ?",
        arguments: [
          nextState.rawValue,
          now,
          usage.promptTokens,
          usage.completionTokens,
          usage.costUSD,
          turn.runId,
        ]
      )
      try Self.insertUsage(db, usage)

      for chunk in turn.chunks {
        _ = try Self.insertOutbox(db, runId: turn.runId, chunk: chunk, now: now)
      }

      if turn.setTainted {
        try Self.setSessionTainted(db, sessionId: turn.sessionId, now: now)
      }

      return .committed
    }
  }

  public func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws -> RunCommitResult {
    try database.writeMapping { db in
      guard let currentState = try Self.currentRunState(db, runId: turn.runId) else {
        return .ignored
      }

      guard currentState == .running else {
        if turn.setTainted, currentState == .cancelled {
          try Self.setSessionTainted(db, sessionId: turn.sessionId, now: now)
        }
        if let usage = turn.usage {
          return try Self.recordTerminalUsageIfNeeded(
            db,
            usage: usage,
            state: currentState,
            now: now
          )
        }
        return .ignored
      }

      guard try Self.transitionRun(db, runId: turn.runId, event: .fail, now: now) != nil else {
        return .ignored
      }
      try Self.appendJobFailedIfJobRun(db, runId: turn.runId, now: now)

      // Executed tool work survives the failure commit: the same §11 rows the success
      // path writes, so the next turn's context and the per-dispatch audit trail agree on what
      // actually ran.
      for exchange in turn.exchanges {
        try Self.insertExchangeRows(
          db,
          sessionId: turn.sessionId,
          runId: turn.runId,
          exchange: exchange,
          now: now
        )
      }

      if let usage = turn.usage {
        try Self.insertUsage(db, usage)
        try Self.updateRunUsage(db, usage: usage, now: now)
      }

      _ = try Self.insertOutbox(db, runId: turn.runId, chunk: turn.chunk, now: now)

      if turn.setTainted {
        try Self.setSessionTainted(db, sessionId: turn.sessionId, now: now)
      }

      return .committed
    }
  }

  public func failRun(runId: Int64, now: Date) throws {
    try database.writeMapping { db in
      guard try Self.transitionRun(db, runId: runId, event: .fail, now: now) != nil else {
        return
      }
      try Self.appendJobFailedIfJobRun(db, runId: runId, now: now)
    }
  }

  public func resolveDeniedObservation(
    runId: Int64,
    observationMessageId: Int64,
    content: String,
    cancel: CancelReason?,
    now: Date
  ) throws -> RunCommitResult {
    try database.writeMapping { db in
      // Fill the placeholder observation in place (§6.4): both `ContextBuilder.historyGroups` and
      // `HistoryHygiene` require every anchor's tool rows to be answered, so a dangling
      // "awaiting owner approval" row would drop the whole exchange from the next assembly. The
      // UPDATE is by message id — idempotent on a boot re-park, and correct for the /stop//new
      // path where the command transaction moved the run but never touched this row.
      try db.execute(
        sql: "UPDATE messages SET content = ? WHERE id = ?",
        arguments: [content, observationMessageId]
      )

      let event: RunEvent =
        switch cancel {
        case .none: .resolveDenied
        case .cancelled: .cancel
        case .superseded: .supersede
        }
      // For the command path the run is already CANCELLED/SUPERSEDED, so the FSM returns nil and we
      // report `.ignored`: the observation fix above was the only remaining work.
      guard let nextState = try Self.transitionRun(db, runId: runId, event: event, now: now) else {
        return .ignored
      }
      if nextState == .failed {
        try Self.appendJobFailedIfJobRun(db, runId: runId, now: now)
      }
      return .committed
    }
  }

  public func commitSuspendedTurn(
    runId: Int64,
    sessionId: Int64,
    commit: SuspendedTurnCommit,
    now: Date
  ) throws -> SuspendedCommitReceipt {
    try database.writeMapping { db in
      guard
        try Self.transitionRun(db, runId: runId, event: .suspendForApproval, now: now) != nil
      else {
        throw StoreError.unexpected("run \(runId) was not RUNNING at suspend commit")
      }

      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_calls)
          VALUES (?, ?, 'assistant', ?, 'trusted', ?, ?)
          """,
        arguments: [sessionId, runId, commit.assistantContent, now, commit.toolCallsJSON]
      )

      for observation in commit.completedObservations {
        try db.execute(
          sql: """
            INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
            VALUES (?, ?, 'tool', ?, 'untrusted', ?, ?)
            """,
          arguments: [sessionId, runId, observation.content, now, observation.toolCallId]
        )
      }
      // The PLACEHOLDER pins rowid adjacency: a real `tool` row satisfying the anchor's expected
      // tool_call_id so `HistoryHygiene` keeps the exchange while parked (§5.3). Resolution UPDATEs
      // it in place (v4 FTS triggers cover the edit).
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', ?, 'untrusted', ?, ?)
          """,
        arguments: [
          sessionId, runId, Self.placeholderObservationContent, now, commit.pending.toolCallId,
        ]
      )
      let observationMessageId = db.lastInsertedRowID

      // policy_version copied from the run row IN-txn (§3.2); empty when unstamped.
      let policyVersion =
        try String.fetchOne(
          db,
          sql: "SELECT policy_version FROM runs WHERE id = ?",
          arguments: [runId]
        ) ?? ""

      let recorded = commit.pending.recorded
      let approvalId = try ApprovalStoreGRDB.insertApproval(
        db,
        NewApproval(
          runId: runId,
          sessionId: sessionId,
          tool: recorded.tool,
          canonicalArgsJSON: recorded.canonicalArgsJSON,
          canonicalTarget: recorded.canonicalTarget,
          argsHash: recorded.argsHash,
          policyVersion: policyVersion,
          ownerUserId: commit.ownerUserId,
          nonce: commit.nonce,
          observationMessageId: observationMessageId,
          toolCallId: commit.pending.toolCallId,
          reason: recorded.reason,
          createdTs: now,
          expiresTs: commit.expiresTs
        )
      )

      if commit.setTainted {
        try Self.setSessionTainted(db, sessionId: sessionId, now: now)
      }
      if commit.setPrivateData {
        try Self.setSessionPrivateData(db, sessionId: sessionId, now: now)
      }

      // No usage insert here — the suspending round's `provider_usage` row was already written
      // mid-loop by `AgentRuntime`; re-inserting would double-debit the budget and resume carry-over.

      // Stamp the new approval id onto the button-carrying chunk so `markSent` can link
      // `prompt_message_id` (Task 10); explanation chunks keep their nil approval_id.
      for chunk in commit.promptChunks {
        let linked = OutboxChunk(
          stepIndex: chunk.stepIndex,
          chatId: chunk.chatId,
          payload: chunk.payload,
          payloadHash: chunk.payloadHash,
          approvalId: chunk.replyMarkup != nil ? approvalId : chunk.approvalId,
          replyMarkup: chunk.replyMarkup
        )
        _ = try Self.insertOutbox(db, runId: runId, chunk: linked, now: now)
      }

      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .assistant,
          action: .approvalRequested,
          tool: recorded.tool,
          decision: recorded.reason.rawValue,
          runId: runId,
          sessionId: sessionId,
          ts: now
        )
      )

      try suspendCommitFault()

      return SuspendedCommitReceipt(
        approvalId: approvalId,
        observationMessageId: observationMessageId
      )
    }
  }

  public func reconcileRunsAtBoot(
    now: Date,
    degradationText: String,
    heartbeatNoticeChatId: Int64?
  ) throws -> [DegradationReply] {
    try database.writeMapping { db in
      let stale = try Row.fetchAll(
        db,
        sql: """
          SELECT r.id AS run_id, r.job_id AS job_id, s.session_key AS session_key FROM runs r
          JOIN sessions s ON s.id = r.session_id
          WHERE r.state IN (?, ?)
          ORDER BY r.id ASC
          """,
        arguments: [RunState.pending.rawValue, RunState.running.rawValue]
      )

      var replies: [DegradationReply] = []
      for row in stale {
        let runId: Int64 = row["run_id"]
        guard try Self.transitionRun(db, runId: runId, event: .fail, now: now) != nil else {
          continue
        }

        try Self.appendJobFailedIfJobRun(db, runId: runId, now: now)

        let jobId: Int64? = row["job_id"]
        let sessionKey: String = row["session_key"]
        let noticeChatId: Int64?
        if let jobId {
          noticeChatId = try Int64.fetchOne(
            db,
            sql: "SELECT owner_chat_id FROM scheduled_jobs WHERE id = ?",
            arguments: [jobId]
          )
        } else if sessionKey == SessionKey.heartbeat {
          // Spec §12/A6: the heartbeat session has no chat id anywhere in the DB — the notice
          // rides the config-derived owner target the boot caller resolved.
          noticeChatId = heartbeatNoticeChatId
        } else {
          noticeChatId = SessionKey.chatId(from: sessionKey)
        }

        let sentCount =
          try Int.fetchOne(
            db,
            sql: """
              SELECT COUNT(*) FROM outbound_deliveries
              WHERE run_id = ? AND status = 'SENT'
              """,
            arguments: [runId]
          ) ?? 0
        guard sentCount == 0, let chatId = noticeChatId else {
          continue
        }

        let chunk = OutboxChunk(
          stepIndex: 0,
          chatId: chatId,
          payload: degradationText,
          payloadHash: ContentHash.fnv1a(degradationText)
        )
        if try Self.insertOutbox(db, runId: runId, chunk: chunk, now: now) {
          replies.append(DegradationReply(chatId: chatId, runId: runId, text: degradationText))
        }
      }

      return replies
    }
  }

  public func runsHealth(now: Date) throws -> RunsHealth {
    try database.readMapping { db in
      let activeStates = [
        RunState.pending.rawValue,
        RunState.running.rawValue,
        RunState.awaitingApproval.rawValue,
      ]
      let inFlight =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM runs WHERE state IN (?, ?, ?)",
          arguments: StatementArguments(activeStates)
        ) ?? 0

      let oldestRunAgeSeconds: Double? =
        try Date.fetchOne(
          db,
          sql: "SELECT MIN(created_ts) FROM runs WHERE state IN (?, ?, ?)",
          arguments: StatementArguments(activeStates)
        ).map { now.timeIntervalSince($0) }

      let lastFailedAt = try Date.fetchOne(
        db,
        sql: "SELECT MAX(updated_ts) FROM runs WHERE state = ?",
        arguments: [RunState.failed.rawValue]
      )

      let lastSuccessAt = try Date.fetchOne(
        db,
        sql: "SELECT MAX(updated_ts) FROM runs WHERE state = ?",
        arguments: [RunState.done.rawValue]
      )

      // Scan the 50 most-recent runs newest-first; count the leading streak of FAILED rows.
      let recentStates = try String.fetchAll(
        db,
        sql: "SELECT state FROM runs ORDER BY id DESC LIMIT 50"
      )
      var consecutiveFailures = 0
      for state in recentStates {
        guard state == RunState.failed.rawValue else { break }
        consecutiveFailures += 1
      }

      return RunsHealth(
        inFlight: inFlight,
        oldestRunAgeSeconds: oldestRunAgeSeconds,
        lastFailedAt: lastFailedAt,
        lastSuccessAt: lastSuccessAt,
        consecutiveFailures: consecutiveFailures
      )
    }
  }
}

// MARK: - Approved Resume (Task 16)

extension RunStoreGRDB {
  public func completeApprovedObservation(
    runId: Int64,
    observationMessageId: Int64,
    content: String,
    now: Date
  ) throws -> RunCommitResult {
    try database.writeMapping { db in
      // Exactly-once (§6.3): the run flips AWAITING_APPROVAL → RUNNING through the reducer. A
      // duplicate resume finds the run already RUNNING (or terminal) and no-ops — the observation
      // (and, for memory_write, the fused insert) never double-apply. This is equivalent to the
      // spec's "observation still placeholder" guard because the placeholder is only ever filled
      // inside this same transaction.
      guard try Self.transitionRun(db, runId: runId, event: .resumeApproved, now: now) != nil else {
        return .ignored
      }
      try Self.fillApprovedObservation(
        db,
        runId: runId,
        messageId: observationMessageId,
        content: content
      )
      return .committed
    }
  }

  public func applyApprovedMemoryWrite(
    runId: Int64,
    observationMessageId: Int64,
    item: NewMemoryItem,
    observationContent: String,
    now: Date
  ) throws -> RunCommitResult {
    try database.writeMapping { db in
      guard try Self.transitionRun(db, runId: runId, event: .resumeApproved, now: now) != nil else {
        return .ignored
      }
      // §6.3 exactly-once: the item insert shares this transaction with the observation fill, both
      // gated by the AWAITING_APPROVAL → RUNNING flip above (D10 — the same db-scoped static
      // `applyRemember` uses; MemoryStore.append would open its own txn and could not fuse).
      _ = try MemoryStoreGRDB.insertItem(db, item: item, now: now)
      try Self.fillApprovedObservation(
        db,
        runId: runId,
        messageId: observationMessageId,
        content: observationContent
      )
      return .committed
    }
  }

  public func resumeUsage(runId: Int64) throws -> ResumeUsage {
    try database.readMapping { db in
      let rounds =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM messages WHERE run_id = ? AND role = 'assistant'",
          arguments: [runId]
        ) ?? 0
      let toolCalls =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM messages WHERE run_id = ? AND role = 'tool'",
          arguments: [runId]
        ) ?? 0
      let tokens =
        try Int.fetchOne(
          db,
          sql: """
            SELECT COALESCE(SUM(prompt_tokens + completion_tokens), 0)
            FROM provider_usage WHERE run_id = ?
            """,
          arguments: [runId]
        ) ?? 0
      let costUSD =
        try Double.fetchOne(
          db,
          sql: "SELECT COALESCE(SUM(cost_usd), 0) FROM provider_usage WHERE run_id = ?",
          arguments: [runId]
        ) ?? 0
      return ResumeUsage(rounds: rounds, toolCalls: toolCalls, tokens: tokens, costUSD: costUSD)
    }
  }

  public func runOrigin(runId: Int64) throws -> RunOrigin? {
    try database.readMapping { db in
      let rawOrigin = try String.fetchOne(
        db,
        sql: "SELECT origin FROM runs WHERE id = ?",
        arguments: [runId]
      )
      guard let rawOrigin else {
        return nil
      }
      // Fail closed on a corrupted origin, same rule as `pickUp`: a mislabeled origin would
      // misroute the continuation's budget pool.
      guard let origin = RunOrigin(rawValue: rawOrigin) else {
        throw StoreError.unexpected("runs row \(runId) has an unrecognized origin")
      }
      return origin
    }
  }

  public func failRunStalePolicy(runId: Int64, sessionId: Int64, now: Date) throws -> Bool {
    try database.writeMapping { db in
      guard try Self.transitionRun(db, runId: runId, event: .fail, now: now) != nil else {
        return false
      }
      try Self.appendJobFailedIfJobRun(db, runId: runId, now: now)
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .system,
          action: .approvalDenied,
          decision: ApprovalDecision.stalePolicy.rawValue,
          runId: runId,
          sessionId: sessionId,
          ts: now
        )
      )
      return true
    }
  }
}

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

  /// The parked-observation body (§5.3). A resolution overwrites it in place with the real result.
  static let placeholderObservationContent = "awaiting owner approval"

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

  /// UPDATEs the reserved placeholder observation row in place with the resolved result. Scoped to
  /// the run + `role = 'tool'` so a stray id can never rewrite an unrelated row. The v4 FTS5
  /// synchronize triggers cover the UPDATE — no extra index work.
  static func fillApprovedObservation(
    _ db: Database,
    runId: Int64,
    messageId: Int64,
    content: String
  ) throws {
    try db.execute(
      sql: "UPDATE messages SET content = ? WHERE id = ? AND run_id = ? AND role = 'tool'",
      arguments: [content, messageId, runId]
    )
  }
}

// MARK: - Turn Commit Helpers

private extension RunStoreGRDB {
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

  static func recordTerminalUsageIfNeeded(
    _ db: Database,
    usage: ProviderUsage,
    state: RunState,
    now: Date
  ) throws -> RunCommitResult {
    guard state == .cancelled || state == .superseded else {
      return .ignored
    }

    let existingRows =
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM provider_usage WHERE run_id = ?",
        arguments: [usage.runId]
      ) ?? 0
    guard existingRows == 0 else {
      return .ignored
    }

    try insertUsage(db, usage)
    try updateRunUsage(db, usage: usage, now: now)

    return .usageRecordedAfterTerminal
  }

  static func updateRunUsage(_ db: Database, usage: ProviderUsage, now: Date) throws {
    try db.execute(
      sql: """
        UPDATE runs SET updated_ts = ?, input_tokens = ?, output_tokens = ?, cost_usd = ?
        WHERE id = ?
        """,
      arguments: [
        now,
        usage.promptTokens,
        usage.completionTokens,
        usage.costUSD,
        usage.runId,
      ]
    )
  }

  static func setSessionTainted(_ db: Database, sessionId: Int64, now: Date) throws {
    try db.execute(
      sql: "UPDATE sessions SET tainted = 1, updated_ts = ? WHERE id = ?",
      arguments: [now, sessionId]
    )
  }

  /// §4.5 set-leg: the sticky private-data flag rides the suspend commit from its first landing
  /// (D6). The read-leg, gate-leg, and `/new` clear land in Task 23 — this is set-only.
  static func setSessionPrivateData(_ db: Database, sessionId: Int64, now: Date) throws {
    try db.execute(
      sql: "UPDATE sessions SET has_private_data = 1, updated_ts = ? WHERE id = ?",
      arguments: [now, sessionId]
    )
  }

  /// Writes one exchange as rows: the assistant anchor (tool_calls JSON, trusted) then each
  /// observation (raw content, untrusted, tool_call_id) — spec §11 row shapes.
  static func insertExchangeRows(
    _ db: Database,
    sessionId: Int64,
    runId: Int64,
    exchange: ToolExchange,
    now: Date
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_calls)
        VALUES (?, ?, 'assistant', ?, 'trusted', ?, ?)
        """,
      arguments: [
        sessionId, runId, exchange.assistantContent, now, ToolCallCoding.encode(exchange.toolCalls),
      ]
    )
    for observation in exchange.observations {
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', ?, 'untrusted', ?, ?)
          """,
        arguments: [sessionId, runId, observation.content, now, observation.callId]
      )
    }
  }
}
