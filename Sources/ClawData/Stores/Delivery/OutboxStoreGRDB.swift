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

  public func claimConferenceNotice(_ chunk: ConferenceNoticeChunk) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      try Self.insertRunlessNotice(
        db,
        subjectDigest: "conference:\(chunk.submissionID.uuidString.lowercased())",
        ordinal: chunk.ordinal,
        chatId: chunk.chatId,
        payload: chunk.payload,
        payloadHash: chunk.payloadHash,
        replyMarkup: nil,
        source: .conference,
        now: Date()
      )
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
      try db.execute(
        sql: """
          UPDATE approvals SET prompt_message_id = ?
          WHERE id = (SELECT approval_id FROM outbound_deliveries WHERE dedup_key = ?)
          """,
        arguments: [telegramMessageId, deliveryKey]
      )
    }
  }

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
  static func insertNotice(
    _ db: Database,
    chunk: LearningNoticeChunk,
    now: Date
  ) throws -> Bool {
    try insertRunlessNotice(
      db,
      subjectDigest: chunk.subjectDigest,
      ordinal: chunk.ordinal,
      chatId: chunk.chatId,
      payload: chunk.payload,
      payloadHash: chunk.payloadHash,
      replyMarkup: chunk.replyMarkup,
      source: .learning,
      now: now
    )
  }

  static func insertRunlessNotice(
    _ db: Database,
    subjectDigest: String,
    ordinal: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String,
    replyMarkup: String?,
    source: DeliverySource,
    now: Date
  ) throws -> Bool {
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key,
          payload, payload_hash, reply_markup, status, created_ts, delivery_source)
        VALUES (NULL, ?, ?, ?, ?, ?, ?, 'PENDING', ?, ?)
        """,
      arguments: [
        ordinal,
        chatId,
        OutboxDedupKey.make(subjectDigest: subjectDigest, ordinal: ordinal),
        payload,
        payloadHash,
        replyMarkup,
        now,
        source.rawValue,
      ]
    )
    return db.changesCount > 0
  }
}
