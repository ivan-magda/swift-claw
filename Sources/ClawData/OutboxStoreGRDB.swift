import ClawCore
import Foundation
import GRDB

public struct OutboxStoreGRDB: OutboxStore {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func claimOutbound(
    runId: Int64,
    stepIndex: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String
  ) throws -> Bool {
    try writer.write { db in
      try RunStoreGRDB.insertOutbox(
        db,
        runId: runId,
        chunk: OutboxChunk(
          stepIndex: stepIndex,
          chatId: chatId,
          payload: payload,
          payloadHash: payloadHash
        ),
        now: Date()
      )
      return db.changesCount > 0
    }
  }

  public func markSent(runId: Int64, stepIndex: Int, telegramMessageId: Int64, now: Date) throws {
    try writer.write { db in
      try db.execute(
        sql: """
          UPDATE outbound_deliveries SET status = 'SENT', telegram_message_id = ?, sent_ts = ?
          WHERE dedup_key = ?
          """,
        arguments: [telegramMessageId, now, "\(runId):\(stepIndex)"]
      )
    }
  }

  public func pendingOutbound() throws -> [OutboxRow] {
    try writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT run_id, step_index, chat_id, payload FROM outbound_deliveries
          WHERE status = 'PENDING' ORDER BY run_id, step_index
          """
      ).map { row in
        OutboxRow(
          runId: row["run_id"],
          stepIndex: row["step_index"],
          chatId: row["chat_id"],
          payload: row["payload"]
        )
      }
    }
  }
}
