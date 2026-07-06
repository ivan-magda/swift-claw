import ClawCore
import Foundation
import GRDB

public struct RunStoreGRDB: RunStore {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func pickUp(runId: Int64, now: Date) throws -> RunOrigin? {
    try writer.writeMapping { db in
      guard try Self.transitionRun(db, runId: runId, event: .pickUp, now: now) != nil else {
        return nil
      }

      let rawOrigin =
        try String.fetchOne(db, sql: "SELECT origin FROM runs WHERE id = ?", arguments: [runId])
        ?? RunOrigin.interactive.rawValue
      // Fail closed: an unknown origin (unwritable via the closed enum) runs reduced-privilege,
      // never interactive.
      return RunOrigin(rawValue: rawOrigin) ?? .scheduled
    }
  }

  public func cancelActiveRun(
    sessionId: Int64,
    reason: CancelReason,
    now: Date
  ) throws -> Int64? {
    try writer.writeMapping { db in
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
    try writer.writeMapping { db in
      try Self.supersedeRuns(db, sessionId: sessionId, now: now)
    }
  }

  public func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws -> RunCommitResult {
    try writer.writeMapping { db in
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
    try writer.writeMapping { db in
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
    try writer.writeMapping { db in
      guard try Self.transitionRun(db, runId: runId, event: .fail, now: now) != nil else {
        return
      }
      try Self.appendJobFailedIfJobRun(db, runId: runId, now: now)
    }
  }

  public func reconcileRunsAtBoot(
    now: Date,
    degradationText: String
  ) throws -> [DegradationReply] {
    try writer.writeMapping { db in
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

        // A6: job runs resolve the crash-notice target via the job row — sessions carry no chat
        // id and the synthetic `sched:job:<id>` key parses to nil. Heartbeat runs (job_id NULL,
        // `sched:heartbeat`) keep skipping here; Phase 4 routes them via config.
        let jobId: Int64? = row["job_id"]
        let noticeChatId: Int64?
        if let jobId {
          noticeChatId = try Int64.fetchOne(
            db,
            sql: "SELECT owner_chat_id FROM scheduled_jobs WHERE id = ?",
            arguments: [jobId]
          )
        } else {
          noticeChatId = SessionKey.chatId(from: row["session_key"])
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
    try writer.readMapping { db in
      let activeStates = [RunState.pending.rawValue, RunState.running.rawValue]
      let inFlight =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM runs WHERE state IN (?, ?)",
          arguments: StatementArguments(activeStates)
        ) ?? 0

      let oldestRunAgeSeconds: Double? =
        try Date.fetchOne(
          db,
          sql: "SELECT MIN(created_ts) FROM runs WHERE state IN (?, ?)",
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
    let jobId: Int64? = row["job_id"]
    guard let jobId else {
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
        WHERE session_id = ? AND state = ?
        ORDER BY id DESC
        LIMIT 1
        """,
      arguments: [sessionId, RunState.running.rawValue]
    )
  }

  static func supersedeRuns(_ db: Database, sessionId: Int64, now: Date) throws -> [Int64] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT id FROM runs
        WHERE session_id = ? AND state IN (?, ?)
        ORDER BY id ASC
        """,
      arguments: [sessionId, RunState.pending.rawValue, RunState.running.rawValue]
    )

    var affected: [Int64] = []
    for row in rows {
      let runId: Int64 = row["id"]
      if try transitionRun(db, runId: runId, event: .supersede, now: now) != nil {
        affected.append(runId)
      }
    }

    return affected
  }

  static func transitionRun(
    _ db: Database,
    runId: Int64,
    event: RunEvent,
    now: Date
  ) throws -> RunState? {
    guard
      let state = try currentRunState(db, runId: runId),
      let nextState = RunFSM.reduce(state: state, on: event)
    else {
      return nil
    }

    try db.execute(
      sql: "UPDATE runs SET state = ?, updated_ts = ? WHERE id = ?",
      arguments: [nextState.rawValue, now, runId]
    )

    return nextState
  }

  private static func currentRunState(_ db: Database, runId: Int64) throws -> RunState? {
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

  private static func recordTerminalUsageIfNeeded(
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

  private static func updateRunUsage(_ db: Database, usage: ProviderUsage, now: Date) throws {
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

  private static func setSessionTainted(_ db: Database, sessionId: Int64, now: Date) throws {
    try db.execute(
      sql: "UPDATE sessions SET tainted = 1, updated_ts = ? WHERE id = ?",
      arguments: [now, sessionId]
    )
  }

  /// Writes one exchange as rows: the assistant anchor (tool_calls JSON, trusted) then each
  /// observation (raw content, untrusted, tool_call_id) — spec §11 row shapes.
  private static func insertExchangeRows(
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

  static func insertOutbox(
    _ db: Database,
    runId: Int64,
    chunk: OutboxChunk,
    now: Date
  ) throws -> Bool {
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
          payload_hash, status, created_ts)
        VALUES (?, ?, ?, ?, ?, ?, 'PENDING', ?)
        """,
      arguments: [
        runId,
        chunk.stepIndex,
        chunk.chatId,
        "\(runId):\(chunk.stepIndex)",
        chunk.payload,
        chunk.payloadHash,
        now,
      ]
    )
    return db.changesCount > 0
  }
}
