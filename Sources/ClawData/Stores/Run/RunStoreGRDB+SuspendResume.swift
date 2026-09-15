import ClawCore
import Foundation
import GRDB

// MARK: - Suspend Commit

extension RunStoreGRDB {
  /// The parked-observation body. A resolution overwrites it in place with the real result.
  static let placeholderObservationContent = "awaiting owner approval"

  public func commitSuspendedTurn(
    runID: Int64,
    sessionID: Int64,
    commit: SuspendedTurnCommit,
    now: Date
  ) throws(StoreError) -> SuspendedCommitReceipt {
    try database.writeMapping { db in
      guard
        try Self.transitionRun(
          db,
          runID: runID,
          event: .suspendForApproval,
          now: now,
          terminal: nil
        ) != nil
      else {
        throw StoreError.unexpected("run \(runID) was not RUNNING at suspend commit")
      }

      let parked = try Self.parkPendingApproval(
        db,
        runID: runID,
        sessionID: sessionID,
        commit: commit,
        now: now
      )

      if commit.setTainted {
        try Self.setSessionTainted(db, sessionID: sessionID, now: now)
      }
      if commit.setPrivateData {
        try Self.setSessionPrivateData(db, sessionID: sessionID, now: now)
      }

      // No usage insert here — the suspending round's `provider_usage` row was already written
      // mid-loop by `AgentRuntime`, so the commit has nothing left to persist.

      try Self.enqueuePromptChunks(
        db,
        runID: runID,
        chunks: commit.promptChunks,
        approvalID: parked.approvalID,
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
          runID: runID,
          sessionID: sessionID,
          ts: now
        )
      )

      try suspendCommitFault()

      return SuspendedCommitReceipt(
        approvalID: parked.approvalID,
        observationMessageID: parked.observationMessageID
      )
    }
  }
}

// MARK: - Approved Resume

extension RunStoreGRDB {
  /// The shared claim body: exactly-once needs BOTH guards. The placeholder check is
  /// per-approval — once the run suspends a second time it is AWAITING_APPROVAL again, so the
  /// state flip alone would let a replay of an already-executed approval commit and steal the new
  /// approval's park. A failed state flip with the placeholder intact means `/stop`//`new` drove
  /// the run terminal after the approve CAS: resolve the placeholder in the SAME txn (history
  /// never dangles) and tell the caller nothing may execute.
  static func claimResume(
    _ db: Database,
    runID: Int64,
    observationMessageID: Int64,
    notResumableObservationContent: String,
    now: Date
  ) throws -> ApprovedExecutionClaim {
    guard try observationIsPlaceholder(db, runID: runID, messageID: observationMessageID) else {
      return .alreadyResumed
    }
    guard
      try transitionRun(db, runID: runID, event: .resumeApproved, now: now, terminal: nil) != nil
    else {
      try fillApprovedObservation(
        db,
        runID: runID,
        messageID: observationMessageID,
        content: notResumableObservationContent
      )
      return .runNotResumable
    }
    return .committed
  }

  public func claimApprovedExecution(
    runID: Int64,
    observationMessageID: Int64,
    notResumableObservationContent: String,
    now: Date
  ) throws(StoreError) -> ApprovedExecutionClaim {
    try database.writeMapping { db in
      try Self.claimResume(
        db,
        runID: runID,
        observationMessageID: observationMessageID,
        notResumableObservationContent: notResumableObservationContent,
        now: now
      )
    }
  }

  public func fillClaimedObservation(
    runID: Int64,
    observationMessageID: Int64,
    fill: ClaimedObservationFill
  ) throws(StoreError) {
    try database.writeMapping { db in
      try Self.fillClaimedObservation(
        db,
        runID: runID,
        observationMessageID: observationMessageID,
        fill: fill
      )
      try claimedFillFault()
    }
  }

  /// Fills a claimed observation with its result, the state-guarded provenance flags, and the
  /// `.toolCall` audit in the caller's transaction so all three commit or roll back together.
  static func fillClaimedObservation(
    _ db: Database,
    runID: Int64,
    observationMessageID: Int64,
    fill: ClaimedObservationFill
  ) throws {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT session_id, state FROM runs WHERE id = ?",
        arguments: [runID]
      ),
      let state = RunState(rawValue: row["state"])
    else {
      throw StoreError.unexpected("run \(runID) is missing or has an unrecognized state")
    }
    let sessionID: Int64 = row["session_id"]

    try fillApprovedObservation(
      db,
      runID: runID,
      messageID: observationMessageID,
      content: fill.content
    )

    // Provenance follows the run that claimed the action: a running or `/stop`-cancelled window
    // still owns the taint, but a `/new`-superseded window already detainted, so re-flagging it
    // would recontaminate the fresh window. The observation and audit above stay truthful either way.
    if state == .running || state == .cancelled {
      if fill.setTainted {
        try setSessionTainted(db, sessionID: sessionID, now: fill.now)
      }
      if fill.setPrivateData {
        try setSessionPrivateData(db, sessionID: sessionID, now: fill.now)
      }
    }

    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: .assistant,
        action: .toolCall,
        tool: fill.audit.tool,
        argsRedacted: fill.audit.argsRedacted,
        resultSize: fill.content.utf8.count,
        decision: fill.status.rawValue,
        runID: runID,
        sessionID: sessionID,
        ts: fill.now
      )
    )
  }

  public func applyApprovedMemoryWrite(  // swiftlint:disable:this function_parameter_count
    runID: Int64,
    observationMessageID: Int64,
    item: NewMemoryItem,
    observationContent: String,
    audit: ApprovedExecutionAudit,
    notResumableObservationContent: String,
    now: Date
  ) throws(StoreError) -> ApprovedExecutionClaim {
    try database.writeMapping { db in
      let claim = try Self.claimResume(
        db,
        runID: runID,
        observationMessageID: observationMessageID,
        notResumableObservationContent: notResumableObservationContent,
        now: now
      )
      guard claim == .committed else {
        return claim
      }
      // Exactly-once: the item insert shares this transaction with the observation fill and its
      // audit, all gated by the claim guards above — the same db-scoped static `applyRemember`
      // uses; MemoryStore.append would open its own txn and could not fuse.
      _ = try MemoryStoreGRDB.insertItem(db, item: item, now: now)
      try Self.fillClaimedObservation(
        db,
        runID: runID,
        observationMessageID: observationMessageID,
        fill: ClaimedObservationFill(
          content: observationContent,
          status: .ok,
          setTainted: false,
          setPrivateData: false,
          audit: audit,
          now: now
        )
      )
      try claimedFillFault()
      return .committed
    }
  }

  public func resumeUsage(runID: Int64) throws(StoreError) -> ResumeUsage {
    try database.readMapping { db in
      let rounds =
        try Int.fetchOne(
          db,
          sql: """
          SELECT COUNT(*) FROM messages \
          WHERE run_id = ? AND role = '\(MessageRole.assistant.rawValue)'
          """,
          arguments: [runID]
        ) ?? 0
      let toolCalls =
        try Int.fetchOne(
          db,
          sql: """
          SELECT COUNT(*) FROM messages \
          WHERE run_id = ? AND role = '\(MessageRole.tool.rawValue)'
          """,
          arguments: [runID]
        ) ?? 0
      let tokens =
        try Int.fetchOne(
          db,
          sql: """
          SELECT COALESCE(SUM(prompt_tokens + completion_tokens), 0)
          FROM provider_usage WHERE run_id = ?
          """,
          arguments: [runID]
        ) ?? 0
      let costUSD =
        try Double.fetchOne(
          db,
          sql: "SELECT COALESCE(SUM(cost_usd), 0) FROM provider_usage WHERE run_id = ?",
          arguments: [runID]
        ) ?? 0
      return ResumeUsage(rounds: rounds, toolCalls: toolCalls, tokens: tokens, costUSD: costUSD)
    }
  }

  public func jobID(runID: Int64) throws(StoreError) -> Int64? {
    try database.readMapping { db in
      try Int64.fetchOne(db, sql: "SELECT job_id FROM runs WHERE id = ?", arguments: [runID])
    }
  }

  public func runOrigin(runID: Int64) throws(StoreError) -> RunOrigin? {
    try database.readMapping { db in
      let rawOrigin = try String.fetchOne(
        db,
        sql: "SELECT origin FROM runs WHERE id = ?",
        arguments: [runID]
      )
      guard let rawOrigin else {
        return nil
      }
      // Fail closed on a corrupted origin, same rule as `pickUp`: a mislabeled origin would
      // misroute the continuation's budget pool.
      guard let origin = RunOrigin(rawValue: rawOrigin) else {
        throw StoreError.unexpected("runs row \(runID) has an unrecognized origin")
      }
      return origin
    }
  }

  public func failRunStalePolicy(
    runID: Int64,
    sessionID: Int64,
    observationMessageID: Int64,
    observationContent: String,
    now: Date
  ) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      guard
        try Self.transitionRun(
          db,
          runID: runID,
          event: .fail,
          now: now,
          terminal: .settled(.policyBlocked)
        ) != nil
      else {
        return false
      }
      try Self.fillApprovedObservation(
        db,
        runID: runID,
        messageID: observationMessageID,
        content: observationContent
      )
      try Self.appendJobFailedIfJobRun(db, runID: runID, now: now)
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .system,
          action: .approvalDenied,
          decision: ApprovalDecision.stalePolicy.rawValue,
          runID: runID,
          sessionID: sessionID,
          ts: now
        )
      )
      return true
    }
  }

  /// The per-approval half of the exactly-once guard: true while the approval's reserved
  /// observation row still carries the placeholder content, i.e. no resume commit has landed for
  /// THIS approval. Same row scoping as `fillApprovedObservation`.
  static func observationIsPlaceholder(_ db: Database, runID: Int64, messageID: Int64) throws
    -> Bool
  {
    try Bool.fetchOne(
      db,
      sql: """
      SELECT EXISTS(
        SELECT 1 FROM messages
        WHERE id = ? AND run_id = ? AND role = '\(MessageRole.tool.rawValue)' AND content = ?
      )
      """,
      arguments: [messageID, runID, placeholderObservationContent]
    ) ?? false
  }

  /// UPDATEs the reserved placeholder observation row in place with the resolved result. Scoped to
  /// the run + `role = 'tool'` so a stray id can never rewrite an unrelated row. The v4 FTS5
  /// synchronize triggers cover the UPDATE — no extra index work.
  static func fillApprovedObservation(
    _ db: Database,
    runID: Int64,
    messageID: Int64,
    content: String
  ) throws {
    try db.execute(
      sql: """
      UPDATE messages SET content = ? \
      WHERE id = ? AND run_id = ? AND role = '\(MessageRole.tool.rawValue)'
      """,
      arguments: [content, messageID, runID]
    )
  }
}

// MARK: - Suspend Commit Helpers

private extension RunStoreGRDB {
  /// Parks the suspended round durably: the assistant anchor + completed observations + the
  /// PLACEHOLDER row, then the approval row that points back at the placeholder.
  static func parkPendingApproval(
    _ db: Database,
    runID: Int64,
    sessionID: Int64,
    commit: SuspendedTurnCommit,
    now: Date
  ) throws -> (approvalID: Int64, observationMessageID: Int64) {
    // Anchor + completed observations + the PLACEHOLDER, in the one write sequence the
    // exchange-commit path shares, so the column lists cannot drift between them. The PLACEHOLDER
    // goes last: a real `tool` row satisfying the anchor's expected tool_call_id so `HistoryHygiene`
    // keeps the exchange while parked (resolution UPDATEs it in place; v4 FTS triggers cover the
    // edit), and being last leaves `lastInsertedRowID` pointing at it.
    try insertAnchoredObservationRows(
      db,
      sessionID: sessionID,
      runID: runID,
      assistantContent: commit.assistantContent,
      toolCallsJSON: commit.toolCallsJSON,
      providerState: commit.providerState,
      observations: commit.completedObservations.map { observation in
        (toolCallID: observation.toolCallID, content: observation.content)
      } + [(toolCallID: commit.pending.toolCallID, content: placeholderObservationContent)],
      now: now
    )
    let observationMessageID = db.lastInsertedRowID

    // policy_version copied from the run row IN-txn; empty when unstamped.
    let policyVersion =
      try String.fetchOne(
        db,
        sql: "SELECT policy_version FROM runs WHERE id = ?",
        arguments: [runID]
      ) ?? ""

    let recorded = commit.pending.recorded
    let approvalID = try ApprovalStoreGRDB.insertApproval(
      db,
      NewApproval(
        runID: runID,
        sessionID: sessionID,
        tool: recorded.tool,
        canonicalArgsJSON: recorded.canonicalArgsJSON,
        canonicalTarget: recorded.canonicalTarget,
        argsHash: recorded.argsHash,
        policyVersion: policyVersion,
        ownerUserID: commit.ownerUserID,
        nonce: commit.nonce,
        observationMessageID: observationMessageID,
        toolCallID: commit.pending.toolCallID,
        reason: recorded.reason,
        createdTs: now,
        expiresTs: commit.expiresTs
      )
    )
    return (approvalID, observationMessageID)
  }

  /// Stamp the new approval id onto the button-carrying chunk so `markSent` can link
  /// `prompt_message_id`; explanation chunks keep their nil approval_id. The chunks are
  /// re-based past the run's already-enqueued deliveries: a SECOND suspend in one run (approve →
  /// resume → another gated proposal) would otherwise collide with the first prompt's dedup key
  /// and be dropped silently — the run would park with no prompt for the owner to answer.
  static func enqueuePromptChunks(
    _ db: Database,
    runID: Int64,
    chunks: [OutboxChunk],
    approvalID: Int64,
    now: Date
  ) throws {
    let stepBase = try OutboxInsertion.nextOutboxStepBase(db, runID: runID)
    for chunk in chunks {
      let linked = OutboxChunk(
        stepIndex: chunk.stepIndex,
        chatID: chunk.chatID,
        payload: chunk.payload,
        payloadHash: chunk.payloadHash,
        approvalID: chunk.replyMarkup != nil ? approvalID : chunk.approvalID,
        replyMarkup: chunk.replyMarkup
      )
      _ = try OutboxInsertion.insertOutbox(
        db,
        runID: runID,
        chunk: OutboxInsertion.shiftedChunk(linked, by: stepBase),
        now: now
      )
    }
  }
}
