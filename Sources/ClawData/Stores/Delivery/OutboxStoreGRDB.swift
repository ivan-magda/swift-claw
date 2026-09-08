import ClawCore
import Foundation
import GRDB

public struct OutboxStoreGRDB: OutboxStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func claimOutbound(runId: Int64, chunk: OutboxChunk) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      try RunStoreGRDB.insertOutbox(db, runId: runId, chunk: chunk, now: Date())
    }
  }

  public func claimNotice(_ chunk: LearningNoticeChunk) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      try Self.insertNotice(db, chunk: chunk, now: Date())
    }
  }

  public func markSent(
    deliveryKey: String,
    telegramMessageId: Int64,
    now: Date
  ) throws(StoreError) {
    try database.writeMapping { db in
      try db.execute(
        sql: """
          UPDATE outbound_deliveries SET status = 'SENT', telegram_message_id = ?, sent_ts = ?
          WHERE dedup_key = ?
          """,
        arguments: [telegramMessageId, now, deliveryKey]
      )
      // An approval-prompt delivery links its Telegram message to the approval so the
      // buttons can later be disarmed. The write rides THIS transaction; a NULL approval_id makes
      // the subquery yield NULL, so `id = NULL` matches nothing and plain rows stay untouched.
      try db.execute(
        sql: """
          UPDATE approvals SET prompt_message_id = ?
          WHERE id = (SELECT approval_id FROM outbound_deliveries WHERE dedup_key = ?)
          """,
        arguments: [telegramMessageId, deliveryKey]
      )
    }
  }

  /// Runless rows sort last (`run_id IS NULL` orders false before true), so a stuck learning notice
  /// can never stall the answers an owner is actually waiting for; `dedup_key` breaks the remaining
  /// tie so a drain order is reproducible.
  public func pendingOutbound() throws(StoreError) -> [OutboxRow] {
    try database.readMapping { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT dedup_key, run_id, step_index, chat_id, payload, approval_id, reply_markup,
            message_thread_id, reply_to_message_id
          FROM outbound_deliveries
          WHERE status = 'PENDING'
          ORDER BY run_id IS NULL, run_id, step_index, dedup_key
          """
      ).map { row in
        OutboxRow(
          deliveryKey: row["dedup_key"],
          runId: row["run_id"],
          stepIndex: row["step_index"],
          chatId: row["chat_id"],
          payload: row["payload"],
          approvalId: row["approval_id"],
          replyMarkup: row["reply_markup"],
          messageThreadId: row["message_thread_id"],
          replyToMessageId: row["reply_to_message_id"]
        )
      }
    }
  }
}

// MARK: - In-Transaction Notice Insert

extension OutboxStoreGRDB {
  /// The runless outbox insert without a transaction of its own, shared by learning transactions
  /// that must commit a notice and every feedback target exposed by its keyboard atomically.
  static func insertNotice(
    _ db: Database,
    chunk: LearningNoticeChunk,
    now: Date
  ) throws -> Bool {
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key,
          payload, payload_hash, reply_markup, status, created_ts, delivery_source)
        VALUES (NULL, ?, ?, ?, ?, ?, ?, 'PENDING', ?, ?)
        """,
      arguments: [
        chunk.ordinal,
        chunk.chatId,
        OutboxDedupKey.make(subjectDigest: chunk.subjectDigest, ordinal: chunk.ordinal),
        chunk.payload,
        chunk.payloadHash,
        chunk.replyMarkup,
        now,
        DeliverySource.learning.rawValue,
      ]
    )
    return db.changesCount > 0
  }
}
