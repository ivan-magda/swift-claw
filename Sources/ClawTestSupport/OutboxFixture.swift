import ClawCore
import ClawData
import Foundation
import GRDB

public enum OutboxFixture {
  /// Completes an already running turn through its production transaction before delivery tests.
  public static func commitReply(
    in writer: any DatabaseWriter,
    runId: Int64,
    chunks: [OutboxChunk],
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    let runs = RunStoreGRDB(writer: writer)
    guard let chunk = chunks.first,
      let context = try runs.executionContext(runId: runId, fallbackChatId: chunk.chatId)
    else {
      throw StoreError.unexpected("Outbox fixture needs a run and reply chunks")
    }
    let outcome = try runs.commitAssistantTurn(
      AssistantTurn(
        runId: runId,
        sessionId: context.sessionId,
        chatId: chunk.chatId,
        content: chunks.map(\.payload).joined(),
        usage: usageFixture(sessionId: context.sessionId, runId: runId),
        chunks: chunks
      ),
      now: now
    )
    guard outcome == .committed else {
      throw StoreError.unexpected("Outbox fixture reply did not commit")
    }
  }

  /// Seeds dispatcher input directly; learning transaction behavior belongs to producer tests.
  public static func seedNotice(
    in writer: any DatabaseWriter,
    chunk: LearningNoticeChunk,
    deliveryKey: String = UUID().uuidString,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    try writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key,
            payload, payload_hash, reply_markup, status, created_ts, delivery_source)
          VALUES (NULL, ?, ?, ?, ?, ?, ?, 'PENDING', ?, ?)
          """,
        arguments: [
          chunk.ordinal,
          chunk.chatId,
          deliveryKey,
          chunk.payload,
          chunk.payloadHash,
          chunk.replyMarkup,
          now,
          DeliverySource.learning.rawValue,
        ]
      )
    }
  }

  /// Recreates legacy incomplete-run deliveries for the boot reconciler's defensive recovery path.
  public static func seedLegacyRunDelivery(
    in writer: any DatabaseWriter,
    runId: Int64,
    chunk: OutboxChunk,
    deliveryKey: String = UUID().uuidString,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    try writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key,
            payload, payload_hash, status, created_ts)
          VALUES (?, ?, ?, ?, ?, ?, 'PENDING', ?)
          """,
        arguments: [
          runId,
          chunk.stepIndex,
          chunk.chatId,
          deliveryKey,
          chunk.payload,
          chunk.payloadHash,
          now,
        ]
      )
    }
  }
}
