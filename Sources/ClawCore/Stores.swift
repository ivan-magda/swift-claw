import Foundation

public protocol AllowlistStore: Sendable {
  func seedAllowlist(userIds: [Int64]) throws
  func allowlistContains(userId: Int64) throws -> Bool
  func allowlistCount() throws -> Int
}

public protocol ProcessedUpdateStore: Sendable {
  /// INSERT OR IGNORE → true if newly claimed, false if already seen.
  /// Synchronous: no await may span the check, so the dedup claim can't interleave.
  func claimUpdate(updateId: Int64) throws -> Bool
}

public protocol UpdateCursorStore: Sendable {
  func loadCursor() throws -> Int64?
  func advanceCursor(to updateId: Int64) throws
}

public protocol SessionMessageStore: Sendable {
  func loadOrCreateSession(sessionKey: String, now: Date) throws -> Int64
  /// Fused F4 transaction: claim the `update_id` and (only if newly claimed) upsert the session +
  /// insert the user message in ONE `db.write`. Returns `newlyClaimed` + the new ids.
  func claimAndPersistInbound(_ inbound: InboundMessage) throws -> ClaimResult
  /// Most-recent `limit` messages, returned **oldest-first** for context assembly.
  func loadRecentMessages(sessionId: Int64, limit: Int) throws -> [StoredMessage]
}

public protocol RunStore: Sendable {
  func createRun(sessionId: Int64, now: Date) throws -> Int64
  /// F6 atomicity: assistant message + run→DONE + provider_usage + outbox chunk(s) in ONE txn,
  /// committed BEFORE any send.
  func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws
  func failRun(runId: Int64, now: Date) throws
  /// Boot sweep (F22): flip every `RUNNING` row → `FAILED`; for any that delivered nothing,
  /// enqueue a PENDING degradation outbox row and return it for logging.
  func reconcileRunsAtBoot(now: Date, degradationText: String) throws -> [DegradationReply]
}

public protocol UsageStore: Sendable {
  func recordUsage(_ usage: ProviderUsage) throws
  /// Running totals over `provider_usage` for the calendar-day-UTC window containing `now` (D4).
  func todayTokensAndCost(now: Date) throws -> (tokens: Int, costUSD: Double)
}

public protocol OutboxStore: Sendable {
  func claimOutbound(
    runId: Int64,
    stepIndex: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String
  ) throws -> Bool
  func markSent(runId: Int64, stepIndex: Int, telegramMessageId: Int64, now: Date) throws
  func pendingOutbound() throws -> [OutboxRow]
}

public protocol AuditLog: Sendable {
  func appendAudit(_ event: AuditEvent) throws
}
