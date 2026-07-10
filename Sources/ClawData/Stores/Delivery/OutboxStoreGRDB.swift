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

  public func claimOutboundIfRunActive(
    runId: Int64,
    chunk: OutboxChunk
  ) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO outbound_deliveries(
            run_id, step_index, chat_id, dedup_key, payload, payload_hash,
            approval_id, reply_markup, status, created_ts
          )
          SELECT ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?
          WHERE EXISTS (
            SELECT 1 FROM runs WHERE id = ? AND state IN (?, ?)
          )
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
          Date(),
          runId,
          RunState.running.rawValue,
          RunState.awaitingApproval.rawValue,
        ]
      )
      return db.changesCount > 0
    }
  }

  public func markSent(
    runId: Int64,
    stepIndex: Int,
    telegramMessageId: Int64,
    now: Date
  ) throws(StoreError) {
    try database.writeMapping { db in
      let dedupKey = OutboxDedupKey.make(runId: runId, stepIndex: stepIndex)
      try db.execute(
        sql: """
          UPDATE outbound_deliveries SET status = 'SENT', telegram_message_id = ?, sent_ts = ?
          WHERE dedup_key = ?
          """,
        arguments: [telegramMessageId, now, dedupKey]
      )
      // An approval-prompt delivery links its Telegram message to the approval so the
      // buttons can later be disarmed. The write rides THIS transaction; a NULL approval_id makes
      // the subquery yield NULL, so `id = NULL` matches nothing and plain rows stay untouched.
      try db.execute(
        sql: """
          UPDATE approvals SET prompt_message_id = ?
          WHERE id = (SELECT approval_id FROM outbound_deliveries WHERE dedup_key = ?)
          """,
        arguments: [telegramMessageId, dedupKey]
      )
    }
  }

  public func pendingOutbound() throws(StoreError) -> [OutboxRow] {
    try database.readMapping { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT run_id, step_index, chat_id, payload, approval_id, reply_markup
          FROM outbound_deliveries
          WHERE status = 'PENDING' ORDER BY run_id, step_index
          """
      ).map { row in
        OutboxRow(
          runId: row["run_id"],
          stepIndex: row["step_index"],
          chatId: row["chat_id"],
          payload: row["payload"],
          approvalId: row["approval_id"],
          replyMarkup: row["reply_markup"]
        )
      }
    }
  }
}
