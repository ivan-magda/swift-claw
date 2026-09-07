import ClawCore
import Foundation
import GRDB

enum OutboxInsertion {
  static func insertOutbox(
    _ db: Database,
    runId: Int64,
    chunk: OutboxChunk,
    now: Date
  ) throws -> Bool {
    let target = try outboxTarget(db, runId: runId, chatId: chunk.chatId)
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
          payload_hash, approval_id, reply_markup, message_thread_id, reply_to_message_id,
          status, created_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?)
        """,
      arguments: [
        runId,
        chunk.stepIndex,
        chunk.chatId,
        OutboxDedupKey.make(runId: runId, stepIndex: chunk.stepIndex),
        chunk.payload,
        chunk.payloadHash,
        chunk.approvalId,
        chunk.replyMarkup,
        target.messageThreadId,
        target.replyToMessageId,
        now,
      ]
    )
    return db.changesCount > 0
  }

  /// Resolves topic and reply metadata from the originating run; plain chats retain their target.
  static func outboxTarget(
    _ db: Database,
    runId: Int64,
    chatId: Int64
  ) throws -> DeliveryTarget {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT sessions.session_key AS session_key,
          runs.trigger_telegram_message_id AS trigger_telegram_message_id
        FROM runs JOIN sessions ON sessions.id = runs.session_id
        WHERE runs.id = ?
        """,
      arguments: [runId]
    )
    guard let row, SessionKey.mode(from: row["session_key"]) == .group else {
      return .chat(chatId)
    }
    return DeliveryTarget(
      chatId: chatId,
      messageThreadId: SessionKey.threadId(from: row["session_key"]),
      replyToMessageId: row["trigger_telegram_message_id"]
    )
  }

  /// Appended notices start after earlier deliveries, including a suspended turn's approval prompt.
  /// Reusing a step would silently drop the notice under the outbox's dedup constraint.
  static func nextOutboxStepBase(_ db: Database, runId: Int64) throws -> Int {
    try Int.fetchOne(
      db,
      sql: "SELECT COALESCE(MAX(step_index) + 1, 0) FROM outbound_deliveries WHERE run_id = ?",
      arguments: [runId]
    ) ?? 0
  }

  /// The same chunk re-based into the run's delivery sequence (identity when `base == 0`).
  static func shiftedChunk(_ chunk: OutboxChunk, by base: Int) -> OutboxChunk {
    guard base > 0 else {
      return chunk
    }
    return OutboxChunk(
      stepIndex: chunk.stepIndex + base,
      chatId: chunk.chatId,
      payload: chunk.payload,
      payloadHash: chunk.payloadHash,
      approvalId: chunk.approvalId,
      replyMarkup: chunk.replyMarkup
    )
  }
}
