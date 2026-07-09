import ClawCore
import Foundation
import GRDB

public struct OutboxStoreGRDB: OutboxStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func claimOutbound(
    runId: Int64,
    stepIndex: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String
  ) throws -> Bool {
    try database.writeMapping { db in
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
    }
  }

  public func claimOutboundIfRunActive(
    runId: Int64,
    stepIndex: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String
  ) throws -> Bool {
    try database.writeMapping { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO outbound_deliveries(
            run_id, step_index, chat_id, dedup_key, payload, payload_hash, status, created_ts
          )
          SELECT ?, ?, ?, ?, ?, ?, 'PENDING', ?
          WHERE EXISTS (
            SELECT 1 FROM runs WHERE id = ? AND state IN (?, ?)
          )
          """,
        arguments: [
          runId,
          stepIndex,
          chatId,
          "\(runId):\(stepIndex)",
          payload,
          payloadHash,
          Date(),
          runId,
          RunState.running.rawValue,
          RunState.awaitingApproval.rawValue,
        ]
      )
      return db.changesCount > 0
    }
  }

  public func markSent(runId: Int64, stepIndex: Int, telegramMessageId: Int64, now: Date) throws {
    try database.writeMapping { db in
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
    try database.readMapping { db in
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
