import ClawAgent
import ClawCore
import Foundation

// MARK: - Turn Data Carriers

extension TurnRunner {
  /// Everything `runTurn` needs from the stores at turn start, loaded together so `run` and
  /// `resume` share one assembly path.
  struct TurnInputs {
    let snapshot: SessionContextSnapshot
    let buildResult: BuildResult
    let todayTokens: Int
    let todayUSD: Double
    let proactiveTodayUSD: Double
  }

  /// Identifiers plus the single commit-time clock, threaded through the per-result commit helpers
  /// so every write in one turn's commit shares the same timestamp.
  struct CommitContext {
    let runId: Int64
    let sessionId: Int64
    let chatId: Int64
    let mode: ChatMode
    let ownerNotices: [String]
    let origin: RunOrigin
    let committedAt: Date
  }
}

// MARK: - Payload Builders

extension TurnRunner {
  /// Builds the audit row for a finished turn (actor = assistant, the turn's author).
  func turnAudit(
    action: AuditAction,
    runId: Int64,
    sessionId: Int64,
    resultSize: Int = 0,
    decision: String = "ok",
    at ts: Date
  ) -> AuditEvent {
    AuditEvent(
      actor: .assistant,
      action: action,
      resultSize: resultSize,
      decision: decision,
      runId: runId,
      sessionId: sessionId,
      ts: ts
    )
  }

  /// Assembles the owner-visible payload: overflow notices PREPEND, the approval prompt APPENDS.
  /// Single-part payloads (the common case) pass through unchanged.
  func ownerVisiblePayload(
    reply: String,
    ownerNotices: [String],
    appendedNotices: [String] = []
  ) -> String {
    let parts = ownerNotices + [reply] + appendedNotices
    guard parts.count > 1 else {
      return reply
    }
    return parts.joined(separator: "\n\n")
  }

  /// Splits an assistant reply into deterministic outbox chunks (grapheme-capped, FNV-1a hashed).
  /// Mechanical helper for the `.completed` path — not part of the commit ordering.
  func outboxChunks(
    for content: String,
    chatId: Int64,
    finalReplyMarkup: String? = nil
  ) -> [OutboxChunk] {
    let payloads = ReplySplitter.split(text: content)
    return payloads.enumerated().map { index, payload in
      OutboxChunk(
        stepIndex: index,
        chatId: chatId,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload),
        replyMarkup: index == payloads.indices.last ? finalReplyMarkup : nil
      )
    }
  }

  /// The approval prompt as outbox chunks — split at the Telegram message limit with the inline
  /// keyboard on the final chunk; the store stamps `approval_id` onto that keyboard-carrying row.
  func approvalPromptChunks(
    pending: PendingToolAction,
    outcome: TurnOutcome,
    chatId: Int64,
    nonce: String
  ) -> [OutboxChunk] {
    ToolApprovalPrompt.chunks(
      for: ToolApprovalPrompt.Input(
        recorded: pending.recorded,
        taintBanner: outcome.ingestedUntrusted,
        privilegedFileBanner: Self.isPrivilegedFile(pending.recorded.canonicalTarget)
      ),
      chatId: chatId,
      nonce: nonce
    )
  }

  /// Privileged-file banner: every owner-editable file that steers a later turn. Basename match on
  /// the resolved canonical target.
  static func isPrivilegedFile(_ canonicalTarget: String) -> Bool {
    WorkspaceFile.isPromptPrivileged(basename: (canonicalTarget as NSString).lastPathComponent)
  }
}
