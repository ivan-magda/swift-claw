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
