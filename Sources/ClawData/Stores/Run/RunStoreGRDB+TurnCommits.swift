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
          runId: turn.runId,
          usage: turn.usage,
          state: currentState,
          now: now
        )
      }

      // Settled with the terminal row: every primary fact of a DONE turn — the assistant message,
      // its usage and its outbox chunks — commits inside this same transaction.
      guard
        try Self.transitionRun(
          db,
          runId: turn.runId,
          event: .complete,
          now: now,
          terminal: .settled(.taskCompleted)
        ) != nil
      else {
        return .ignored
      }

      let feedbackTargetCommitted = try Self.commitFeedbackTarget(db, turn: turn, now: now)
      try Self.finalizeCompletedTurn(
        db,
        turn: turn,
        feedbackTargetCommitted: feedbackTargetCommitted,
        now: now
      )

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
            runId: turn.runId,
            usage: usage,
            state: currentState,
            now: now
          )
        }
        return .ignored
      }

      guard
        try Self.transitionRun(
          db,
          runId: turn.runId,
          event: .fail,
          now: now,
          terminal: .settled(turn.cause)
        ) != nil
      else {
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
    feedbackTargetCommitted: Bool,
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
      let committedChunk =
        turn.feedbackTarget != nil && feedbackTargetCommitted == false
        ? strippingReplyMarkup(from: chunk)
        : chunk
      _ = try insertOutbox(
        db,
        runId: turn.runId,
        chunk: shiftedChunk(committedChunk, by: stepBase),
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

  /// The cheap caller-side resolution is advisory. This query is the race-closing authority: the
  /// bound scheduled run, current epoch and exact effective lesson row must still agree here.
  static func commitFeedbackTarget(
    _ db: Database,
    turn: AssistantTurn,
    now: Date
  ) throws -> Bool {
    guard let target = turn.feedbackTarget else {
      return false
    }
    let expectedActions: [OwnerSignal] = [
      .resultUseful, .resultNotUseful, .resultCorrection,
    ]
    guard
      target.subjectKind == .run,
      target.subjectDigest == String(turn.runId),
      target.ownerUserId == turn.chatId,
      target.chatId == turn.chatId,
      target.allowedActions == expectedActions,
      target.expiresAt > now
    else {
      return false
    }

    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT binding.job_id, binding.learning_epoch, binding.occurrence_at
        FROM run_learning_bindings AS binding
        JOIN runs AS run ON run.id = binding.run_id AND run.job_id = binding.job_id
        JOIN scheduled_jobs AS job ON job.id = run.job_id AND job.owner_chat_id = ?
        JOIN job_learning_state AS state
          ON state.job_id = binding.job_id
          AND state.learning_epoch = binding.learning_epoch
        JOIN lesson_sets AS effective
          ON effective.job_id = binding.job_id AND effective.digest = binding.effective_digest
        WHERE binding.run_id = ? AND run.origin = ?
        """,
      arguments: [turn.chatId, turn.runId, RunOrigin.scheduled.rawValue]
    )
    guard
      let row,
      target.jobId == row["job_id"],
      target.epoch.value == row["learning_epoch"],
      let occurrenceAt = EpochSecondCodec.date(fromEpoch: row["occurrence_at"]),
      target.expiresAt == occurrenceAt.addingTimeInterval(EvidenceWindow.maximumAge)
    else {
      return false
    }

    let nonceExists =
      try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS(SELECT 1 FROM feedback_targets WHERE nonce = ?)",
        arguments: [target.nonce]
      ) ?? true
    guard nonceExists == false else {
      return false
    }
    try ScheduledLearningStoreGRDB.insertTarget(db, target)
    return true
  }

  static func strippingReplyMarkup(from chunk: OutboxChunk) -> OutboxChunk {
    OutboxChunk(
      stepIndex: chunk.stepIndex,
      chatId: chunk.chatId,
      payload: chunk.payload,
      payloadHash: chunk.payloadHash,
      approvalId: chunk.approvalId,
      replyMarkup: nil
    )
  }

  static func recordTerminalUsageIfNeeded(
    _ db: Database,
    runId: Int64,
    usage: ProviderUsage,
    state: RunState,
    now: Date
  ) throws -> RunCommitResult {
    guard state == .cancelled || state == .superseded else {
      return .ignored
    }

    // Usage is a primary fact, and no primary fact may land once the run's evidence is frozen.
    // Deferring settlement on the cancel/supersede paths is what leaves this window open at all;
    // once the lane tail (or the boot backstop) has closed it, the spend has nowhere truthful to go.
    guard try !ScheduledLearningStoreGRDB.isSettled(db, runId: runId) else {
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
