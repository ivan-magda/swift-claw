import ClawCore
import Foundation
import GRDB

// MARK: - Boot Reconciliation & Health

extension RunStoreGRDB {
  public func reconcileRunsAtBoot(
    now: Date,
    degradationText: String,
    heartbeatNoticeChatId: Int64?
  ) throws(StoreError) -> [DegradationReply] {
    try database.writeMapping { db in
      // AWAITING_APPROVAL is deliberately excluded, not merely omitted: a suspended run is a live
      // durable checkpoint, not a crash orphan. The approval boot reconciliation
      // (ApprovalBootReconciler) owns those runs — re-parking the unexpired ones and running the
      // per-row expiry check on the rest. Only true PENDING/RUNNING orphans fail here.
      let orphanFailStates = [RunState.pending.rawValue, RunState.running.rawValue]
      let stale = try Row.fetchAll(
        db,
        sql: """
          SELECT r.id AS run_id, r.job_id AS job_id, s.session_key AS session_key FROM runs r
          JOIN sessions s ON s.id = r.session_id
          WHERE r.state IN (?, ?)
          ORDER BY r.id ASC
          """,
        arguments: StatementArguments(orphanFailStates)
      )

      var replies: [DegradationReply] = []
      for row in stale {
        let runId: Int64 = row["run_id"]
        let disposition = try Self.orphanDisposition(db, runId: runId)
        guard
          try Self.transitionRun(
            db,
            runId: runId,
            event: .fail,
            now: now,
            terminal: disposition
          ) != nil
        else {
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
          // The heartbeat session has no chat id anywhere in the DB — the notice rides the
          // config-derived owner target the boot caller resolved.
          noticeChatId = heartbeatNoticeChatId
        } else {
          noticeChatId = SessionKey.chatId(from: sessionKey)
        }

        // Suppress the notice only when the owner already saw a genuine REPLY. The newest SENT
        // row decides: an approval-prompt keyboard chunk (approval_id set) means the run
        // suspended, was approved, and died before its continuation replied — the owner has
        // heard nothing since tapping Approve, so the notice must still fire. (A RUNNING orphan
        // can never trail a delivered reply mid-prompt: the keyboard chunk is the prompt's final
        // step and must be SENT before the owner can approve at all.)
        let newestSent = try Row.fetchOne(
          db,
          sql: """
            SELECT approval_id FROM outbound_deliveries
            WHERE run_id = ? AND status = 'SENT'
            ORDER BY step_index DESC LIMIT 1
            """,
          arguments: [runId]
        )
        let ownerSawAReply = newestSent != nil && (newestSent?["approval_id"] as Int64?) == nil
        guard ownerSawAReply == false, let chatId = noticeChatId else {
          continue
        }

        // Re-based like every commit-time enqueue: a run that suspended before the crash already
        // holds its approval prompt at step 0, and a raw step-0 notice would be dropped silently
        // by the dedup key.
        let chunk = OutboxChunk(
          stepIndex: try Self.nextOutboxStepBase(db, runId: runId),
          chatId: chatId,
          payload: degradationText,
          payloadHash: ContentHash.fnv1a(degradationText)
        )
        if try Self.insertOutbox(db, runId: runId, chunk: chunk, now: now) {
          replies.append(DegradationReply(chatId: chatId, runId: runId, text: degradationText))
        }
      }

      // The crash backstop for settlement, not for state: a run that reached its terminal state in
      // a previous process — `/stop` won, then the daemon died before the lane tail returned — has
      // a receipt but no `settled_at`, and would otherwise stay out of the learning loop forever.
      try ScheduledLearningStoreGRDB.settleAbandonedRuns(
        db,
        unresolvedObservationContent: Self.placeholderObservationContent,
        now: now
      )

      return replies
    }
  }

  /// A crashed orphan is `incomplete`: the turn stopped mid-flight and `RunState` alone cannot say
  /// more. One holding an unresolved approval placeholder is the claimed crash window instead — its
  /// approval was granted and claimed, and `settleClaimedApprovalAtBoot` still owes it the
  /// observation, so its evidence must not freeze here.
  static func orphanDisposition(_ db: Database, runId: Int64) throws -> TerminalDisposition {
    let owed =
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM messages
            WHERE run_id = ? AND role = '\(MessageRole.tool.rawValue)' AND content = ?
          )
          """,
        arguments: [runId, Self.placeholderObservationContent]
      ) ?? false
    return owed ? .deferred(.approvalUnresolved) : .settled(.incomplete)
  }

  public func settleClaimedApprovalAtBoot(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    observationMessageId: Int64,
    observationContent: String,
    noticeChatId: Int64,
    noticeText: String,
    now: Date
  ) throws(StoreError) -> ClaimedApprovalBootOutcome {
    try database.writeMapping { db in
      guard
        try Self.observationIsPlaceholder(db, runId: runId, messageId: observationMessageId)
      else {
        return .alreadyResolved
      }
      let state = try String.fetchOne(
        db,
        sql: "SELECT state FROM runs WHERE id = ?",
        arguments: [runId]
      )
      if state == RunState.awaitingApproval.rawValue {
        return .reparkForReplay
      }

      // Claimed, outcome unknown — settle in place. The run is normally already FAILED (the
      // orphan sweep runs first); the transition covers a sweep that missed it and no-ops on any
      // terminal state.
      let transitioned = try Self.transitionRun(
        db,
        runId: runId,
        event: .fail,
        now: now,
        terminal: .deferred(.approvalUnresolved)
      )
      if transitioned != nil {
        try Self.appendJobFailedIfJobRun(db, runId: runId, now: now)
      }
      try Self.fillApprovedObservation(
        db,
        runId: runId,
        messageId: observationMessageId,
        content: observationContent
      )
      // The placeholder was the last fact this run was owed; resolving it is what earns the right
      // to freeze its evidence, which is why neither the orphan sweep nor the transition above did.
      _ = try ScheduledLearningStoreGRDB.freezeEvidence(db, runId: runId, now: now)
      let chunk = OutboxChunk(
        stepIndex: try Self.nextOutboxStepBase(db, runId: runId),
        chatId: noticeChatId,
        payload: noticeText,
        payloadHash: ContentHash.fnv1a(noticeText)
      )
      _ = try Self.insertOutbox(db, runId: runId, chunk: chunk, now: now)
      return .settled
    }
  }

  public func runsHealth(now: Date) throws(StoreError) -> RunsHealth {
    try database.readMapping { db in
      // The one definition of "live" (shared with terminateActiveRuns / the overlap guard) so a
      // new non-terminal state can't drift this health scan out of sync.
      let liveStates = RunState.liveStates.map(\.rawValue)
      let placeholders = databaseQuestionMarks(count: liveStates.count)
      let inFlight =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM runs WHERE state IN (\(placeholders))",
          arguments: StatementArguments(liveStates)
        ) ?? 0

      let oldestRunAgeSeconds: Double? =
        try Date.fetchOne(
          db,
          sql: "SELECT MIN(created_ts) FROM runs WHERE state IN (\(placeholders))",
          arguments: StatementArguments(liveStates)
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
        guard state == RunState.failed.rawValue else {
          break
        }
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
