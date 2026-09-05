import ClawCore
import Foundation

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
}
