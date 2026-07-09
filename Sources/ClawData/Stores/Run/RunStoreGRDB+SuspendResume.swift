import ClawCore
import Foundation
import GRDB

// MARK: - Suspend Commit (§5.3)

extension RunStoreGRDB {
  /// The parked-observation body (§5.3). A resolution overwrites it in place with the real result.
  static let placeholderObservationContent = "awaiting owner approval"

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

      let parked = try Self.parkPendingApproval(
        db,
        runId: runId,
        sessionId: sessionId,
        commit: commit,
        now: now
      )

      if commit.setTainted {
        try Self.setSessionTainted(db, sessionId: sessionId, now: now)
      }
      if commit.setPrivateData {
        try Self.setSessionPrivateData(db, sessionId: sessionId, now: now)
      }

      // No usage insert here — the suspending round's `provider_usage` row was already written
      // mid-loop by `AgentRuntime`; re-inserting would double-debit the budget and resume carry-over.

      try Self.enqueuePromptChunks(
        db,
        runId: runId,
        chunks: commit.promptChunks,
        approvalId: parked.approvalId,
        now: now
      )

      let recorded = commit.pending.recorded
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
        approvalId: parked.approvalId,
        observationMessageId: parked.observationMessageId
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

// MARK: - Suspend Commit Helpers

private extension RunStoreGRDB {
  /// Parks the suspended round durably: the assistant anchor + completed observations + the
  /// PLACEHOLDER row, then the approval row that points back at the placeholder.
  static func parkPendingApproval(
    _ db: Database,
    runId: Int64,
    sessionId: Int64,
    commit: SuspendedTurnCommit,
    now: Date
  ) throws -> (approvalId: Int64, observationMessageId: Int64) {
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
        sessionId, runId, placeholderObservationContent, now, commit.pending.toolCallId,
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
    return (approvalId, observationMessageId)
  }

  /// Stamp the new approval id onto the button-carrying chunk so `markSent` can link
  /// `prompt_message_id` (Task 10); explanation chunks keep their nil approval_id.
  static func enqueuePromptChunks(
    _ db: Database,
    runId: Int64,
    chunks: [OutboxChunk],
    approvalId: Int64,
    now: Date
  ) throws {
    for chunk in chunks {
      let linked = OutboxChunk(
        stepIndex: chunk.stepIndex,
        chatId: chunk.chatId,
        payload: chunk.payload,
        payloadHash: chunk.payloadHash,
        approvalId: chunk.replyMarkup != nil ? approvalId : chunk.approvalId,
        replyMarkup: chunk.replyMarkup
      )
      _ = try insertOutbox(db, runId: runId, chunk: linked, now: now)
    }
  }

  /// §4.5 set-leg: the sticky private-data flag rides the suspend commit from its first landing
  /// (D6). The read-leg, gate-leg, and `/new` clear land in Task 23 — this is set-only.
  static func setSessionPrivateData(_ db: Database, sessionId: Int64, now: Date) throws {
    try db.execute(
      sql: "UPDATE sessions SET has_private_data = 1, updated_ts = ? WHERE id = ?",
      arguments: [now, sessionId]
    )
  }
}
