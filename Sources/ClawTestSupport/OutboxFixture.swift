import ClawCore
import ClawData
import Foundation
import GRDB

public enum OutboxFixture {
  /// Completes an already running turn through its production transaction before delivery tests.
  public static func commitReply(
    in writer: any DatabaseWriter,
    runID: Int64,
    chunks: [OutboxChunk],
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    let runs = RunStoreGRDB(writer: writer)
    guard let chunk = chunks.first,
          let context = try runs.executionContext(runID: runID, fallbackChatID: chunk.chatID)
    else {
      throw StoreError.unexpected("Outbox fixture needs a run and reply chunks")
    }
    let outcome = try runs.commitAssistantTurn(
      AssistantTurn(
        runID: runID,
        sessionID: context.sessionID,
        chatID: chunk.chatID,
        content: chunks.map(\.payload).joined(),
        usage: usageFixture(sessionID: context.sessionID, runID: runID),
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
          chunk.chatID,
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
    runID: Int64,
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
          runID,
          chunk.stepIndex,
          chunk.chatID,
          deliveryKey,
          chunk.payload,
          chunk.payloadHash,
          now,
        ]
      )
    }
  }
}
