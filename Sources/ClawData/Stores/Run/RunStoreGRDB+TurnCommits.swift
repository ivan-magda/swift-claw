import ClawCore
import Foundation
import GRDB

// MARK: - Turn Commits

extension RunStoreGRDB {
  public func commitAssistantTurn(
    _ turn: AssistantTurn,
    now: Date
  ) throws(StoreError) -> RunCommitResult {
    try database.writeMapping { db in
      guard let currentState = try Self.currentRunState(db, runId: turn.runId) else {
        return .ignored
      }

      guard currentState == .running else {
        if turn.setTainted, currentState == .cancelled {
          try Self.setSessionTainted(db, sessionId: turn.sessionId, now: now)
        }
        if turn.setPrivateData, currentState == .cancelled {
          try Self.setSessionPrivateData(db, sessionId: turn.sessionId, now: now)
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

      try Self.finalizeCompletedTurn(db, turn: turn, nextState: nextState, now: now)

      return .committed
    }
  }

  public func commitDegradedTurn(
    _ turn: DegradedTurn,
    now: Date
  ) throws(StoreError) -> RunCommitResult {
    try database.writeMapping { db in
      guard let currentState = try Self.currentRunState(db, runId: turn.runId) else {
        return .ignored
      }

      guard currentState == .running else {
        if turn.setTainted, currentState == .cancelled {
          try Self.setSessionTainted(db, sessionId: turn.sessionId, now: now)
        }
        if turn.setPrivateData, currentState == .cancelled {
          try Self.setSessionPrivateData(db, sessionId: turn.sessionId, now: now)
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

      // Executed tool work survives the failure commit: the same rows the success
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

      // Same collision guard as the completed path: a degraded RESUME must not silently drop
      // its owner-facing reply against the run's already-enqueued approval prompt.
      let stepBase = try Self.nextOutboxStepBase(db, runId: turn.runId)
      _ = try Self.insertOutbox(
        db,
        runId: turn.runId,
        chunk: Self.shiftedChunk(turn.chunk, by: stepBase),
        now: now
      )

      if turn.setTainted {
        try Self.setSessionTainted(db, sessionId: turn.sessionId, now: now)
      }
      if turn.setPrivateData {
        try Self.setSessionPrivateData(db, sessionId: turn.sessionId, now: now)
      }

      return .committed
    }
  }
}

// MARK: - Turn Commit Helpers

private extension RunStoreGRDB {
  static func finalizeCompletedTurn(
    _ db: Database,
    turn: AssistantTurn,
    nextState: RunState,
    now: Date
  ) throws {
    for exchange in turn.exchanges {
      try insertExchangeRows(
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
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        turn.sessionId,
        turn.runId,
        MessageRole.assistant.rawValue,
        turn.content,
        Provenance.trusted.rawValue,
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
    try insertUsage(db, usage)

    let stepBase = try nextOutboxStepBase(db, runId: turn.runId)
    for chunk in turn.chunks {
      _ = try insertOutbox(
        db,
        runId: turn.runId,
        chunk: shiftedChunk(chunk, by: stepBase),
        now: now
      )
    }

    if turn.setTainted {
      try setSessionTainted(db, sessionId: turn.sessionId, now: now)
    }
    if turn.setPrivateData {
      try setSessionPrivateData(db, sessionId: turn.sessionId, now: now)
    }
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

  /// Writes one exchange as rows: the assistant anchor (tool_calls JSON, trusted) then each
  /// observation (raw content, untrusted, tool_call_id).
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
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        sessionId,
        runId,
        MessageRole.assistant.rawValue,
        exchange.assistantContent,
        Provenance.trusted.rawValue,
        now,
        ToolCallCoding.encode(exchange.toolCalls),
      ]
    )
    for observation in exchange.observations {
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId,
          runId,
          MessageRole.tool.rawValue,
          observation.content,
          Provenance.untrusted.rawValue,
          now,
          observation.callId,
        ]
      )
    }
  }
}
