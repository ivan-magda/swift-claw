import ClawCore
import Foundation
import GRDB

enum OutboxInsertion {
  static func insertOutbox(
    _ db: Database,
    runID: Int64,
    chunk: OutboxChunk,
    now: Date
  ) throws -> Bool {
    let target = try outboxTarget(db, runID: runID, chatID: chunk.chatID)
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
          payload_hash, approval_id, reply_markup, message_thread_id, reply_to_message_id,
          status, created_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?)
        """,
      arguments: [
        runID,
        chunk.stepIndex,
        chunk.chatID,
        OutboxDedupKey.make(runID: runID, stepIndex: chunk.stepIndex),
        chunk.payload,
        chunk.payloadHash,
        chunk.approvalID,
        chunk.replyMarkup,
        target.messageThreadID,
        target.replyToMessageID,
        now,
      ]
    )
    return db.changesCount > 0
  }

  /// Resolves topic and reply metadata from the originating run; plain chats retain their target.
  static func outboxTarget(_ db: Database, runID: Int64, chatID: Int64) throws -> DeliveryTarget {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT sessions.session_key AS session_key,
          runs.trigger_telegram_message_id AS trigger_telegram_message_id
        FROM runs JOIN sessions ON sessions.id = runs.session_id
        WHERE runs.id = ?
        """,
      arguments: [runID]
    )
    guard let row, SessionKey.mode(from: row["session_key"]) == .group else {
      return .chat(chatID)
    }
    return DeliveryTarget(
      chatID: chatID,
      messageThreadID: SessionKey.threadID(from: row["session_key"]),
      replyToMessageID: row["trigger_telegram_message_id"]
    )
  }

  /// Appended notices start after earlier deliveries, including a suspended turn's approval prompt.
  /// Reusing a step would silently drop the notice under the outbox's dedup constraint.
  static func nextOutboxStepBase(_ db: Database, runID: Int64) throws -> Int {
    try Int.fetchOne(
      db,
      sql: "SELECT COALESCE(MAX(step_index) + 1, 0) FROM outbound_deliveries WHERE run_id = ?",
      arguments: [runID]
    ) ?? 0
  }

  /// The same chunk re-based into the run's delivery sequence (identity when `base == 0`).
  static func shiftedChunk(_ chunk: OutboxChunk, by base: Int) -> OutboxChunk {
    guard base > 0 else {
      return chunk
    }
    return OutboxChunk(
      stepIndex: chunk.stepIndex + base,
      chatID: chunk.chatID,
      payload: chunk.payload,
      payloadHash: chunk.payloadHash,
      approvalID: chunk.approvalID,
      replyMarkup: chunk.replyMarkup
    )
  }
}
