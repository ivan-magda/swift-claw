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

      guard try Self.transitionRun(db, runId: turn.runId, event: .complete, now: now) != nil else {
        return .ignored
      }

      try Self.finalizeCompletedTurn(db, turn: turn, now: now)

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
        _ = try Self.insertUsage(db, usage)
        try Self.recomputeRunUsageTotals(db, runId: turn.runId, now: now)
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
  /// The run's terminal state is already written by the `transitionRun` that authorised this
  /// commit, so nothing here restates it.
  static func finalizeCompletedTurn(
    _ db: Database,
    turn: AssistantTurn,
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
    try MessageRowInsert.execute(
      db,
      columns: [
        "session_id", "run_id", "role", "content", "provenance", "ts", "prompt_tokens",
        "completion_tokens",
      ],
      values: [
        turn.sessionId,
        turn.runId,
        MessageRole.assistant.rawValue,
        turn.content,
        Provenance.trusted.rawValue,
        now,
        usage.promptTokens,
        usage.completionTokens,
      ],
      providerState: turn.providerState
    )
    _ = try insertUsage(db, usage)
    try recomputeRunUsageTotals(db, runId: turn.runId, now: now)

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

    // Whether this row is new is decided per provider call, not per run. A run legitimately holds
    // one row per tool-loop round, so asking "does this run have usage yet?" would throw away the
    // terminal round's spend for every run whose loop got past its first round — while still
    // double-debiting the one case it meant to guard, a commit retried before its first row
    // landed. The call identity answers the question the guard was actually asking.
    guard try insertUsage(db, usage) else {
      return .ignored
    }

    if let runId = usage.runId {
      try recomputeRunUsageTotals(db, runId: runId, now: now)
    }

    return .usageRecordedAfterTerminal
  }

  /// Re-derives the run's denormalized totals from every usage row it owns, in the same transaction
  /// as the insert that prompted it. This is the ONLY definition of what `runs.input_tokens`,
  /// `output_tokens`, and `cost_usd` mean — what the run spent across every round it recorded —
  /// and every commit path goes through it, so the figure never depends on which path got there.
  ///
  /// Summing what is stored, rather than adding the row in hand, is what makes that possible: it is
  /// idempotent, so it needs no replay guard and is safe to run when the insert conflicted and wrote
  /// nothing. Adding the row in hand would instead let a late row erase the rounds before it, and
  /// let a conflicting insert debit spend the run never incurred.
  static func recomputeRunUsageTotals(_ db: Database, runId: Int64, now: Date) throws {
    try db.execute(
      sql: """
        UPDATE runs SET
          updated_ts = ?,
          input_tokens = (
            SELECT COALESCE(SUM(prompt_tokens), 0) FROM provider_usage WHERE run_id = ?
          ),
          output_tokens = (
            SELECT COALESCE(SUM(completion_tokens), 0) FROM provider_usage WHERE run_id = ?
          ),
          cost_usd = (SELECT COALESCE(SUM(cost_usd), 0) FROM provider_usage WHERE run_id = ?)
        WHERE id = ?
        """,
      arguments: [now, runId, runId, runId, runId]
    )
  }

  /// Writes one completed exchange as rows by encoding its tool calls and handing the anchor plus
  /// observations to the shared write sequence. Observations get no state — the round produced one,
  /// and it belongs to the proposal that made it, not to the untrusted output it fetched.
  static func insertExchangeRows(
    _ db: Database,
    sessionId: Int64,
    runId: Int64,
    exchange: ToolExchange,
    now: Date
  ) throws {
    try insertAnchoredObservationRows(
      db,
      sessionId: sessionId,
      runId: runId,
      assistantContent: exchange.assistantContent,
      toolCallsJSON: ToolCallCoding.encode(exchange.toolCalls),
      providerState: exchange.providerState,
      observations: exchange.observations.map { observation in
        (toolCallId: observation.callId, content: observation.content)
      },
      now: now
    )
  }
}

// MARK: - Shared Anchor-Plus-Observations Write Sequence

extension RunStoreGRDB {
  /// The one anchor-plus-observations write sequence: the assistant anchor (tool_calls JSON,
  /// trusted, carrying the state the proposal was minted with) then each observation (raw content,
  /// untrusted, tool_call_id, no state). Both the completed-exchange commit and the suspend park
  /// write through here, so the column lists and their ordering have a single home and cannot drift
  /// between the two paths.
  static func insertAnchoredObservationRows(  // swiftlint:disable:this function_parameter_count
    _ db: Database,
    sessionId: Int64,
    runId: Int64,
    assistantContent: String,
    toolCallsJSON: String?,
    providerState: ProviderExchangeState?,
    observations: [(toolCallId: String, content: String)],
    now: Date
  ) throws {
    try MessageRowInsert.execute(
      db,
      columns: ["session_id", "run_id", "role", "content", "provenance", "ts", "tool_calls"],
      values: [
        sessionId,
        runId,
        MessageRole.assistant.rawValue,
        assistantContent,
        Provenance.trusted.rawValue,
        now,
        toolCallsJSON,
      ],
      providerState: providerState
    )
    for observation in observations {
      try MessageRowInsert.execute(
        db,
        columns: ["session_id", "run_id", "role", "content", "provenance", "ts", "tool_call_id"],
        values: [
          sessionId,
          runId,
          MessageRole.tool.rawValue,
          observation.content,
          Provenance.untrusted.rawValue,
          now,
          observation.toolCallId,
        ],
        providerState: nil
      )
    }
  }
}
