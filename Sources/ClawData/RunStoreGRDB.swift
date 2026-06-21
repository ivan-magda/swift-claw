import ClawCore
import Foundation
import GRDB

public struct RunStoreGRDB: RunStore {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func createRun(sessionId: Int64, now: Date) throws -> Int64 {
    try writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (?, ?, ?, ?)
          """,
        arguments: [sessionId, RunState.running.rawValue, now, now]
      )
      return db.lastInsertedRowID
    }
  }

  public func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws {
    try writer.write { db in
      let usage = turn.usage
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, prompt_tokens, completion_tokens)
          VALUES (?, ?, 'assistant', ?, 'trusted', ?, ?, ?)
          """,
        arguments: [
          turn.sessionId,
          turn.runId,
          turn.content,
          now,
          usage.promptTokens,
          usage.completionTokens,
        ]
      )
      try db.execute(
        sql:
          "UPDATE runs SET state = ?, updated_ts = ?, input_tokens = ?, output_tokens = ?, cost_usd = ? WHERE id = ?",
        arguments: [
          RunState.done.rawValue,
          now,
          usage.promptTokens,
          usage.completionTokens,
          usage.costUSD,
          turn.runId,
        ]
      )
      try Self.insertUsage(db, usage)
      for chunk in turn.chunks {
        try Self.insertOutbox(db, runId: turn.runId, chunk: chunk, now: now)
      }
    }
  }

  public func failRun(runId: Int64, now: Date) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE runs SET state = ?, updated_ts = ? WHERE id = ?",
        arguments: [RunState.failed.rawValue, now, runId]
      )
    }
  }

  public func reconcileRunsAtBoot(now: Date, degradationText: String) throws -> [DegradationReply] {
    try writer.write { db in
      let stale = try Row.fetchAll(
        db,
        sql: """
          SELECT r.id AS run_id, s.session_key AS session_key FROM runs r
          JOIN sessions s ON s.id = r.session_id WHERE r.state = ?
          """,
        arguments: [RunState.running.rawValue]
      )

      var replies: [DegradationReply] = []
      for row in stale {
        let runId: Int64 = row["run_id"]
        try db.execute(
          sql: "UPDATE runs SET state = ?, updated_ts = ? WHERE id = ?",
          arguments: [RunState.failed.rawValue, now, runId]
        )
        let delivered =
          try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM outbound_deliveries WHERE run_id = ?",
            arguments: [runId]
          ) ?? 0
        // A delivered run committed its reply before the crash; the dispatcher resends it.
        // An undelivered run left the owner in silence — enqueue the degradation reply.
        guard
          delivered == 0,
          let chatId = SessionKey.chatId(from: row["session_key"])
        else {
          continue
        }

        let chunk = OutboxChunk(
          stepIndex: 0,
          chatId: chatId,
          payload: degradationText,
          payloadHash: Self.hash(degradationText)
        )
        try Self.insertOutbox(db, runId: runId, chunk: chunk, now: now)

        replies.append(DegradationReply(chatId: chatId, runId: runId, text: degradationText))
      }

      return replies
    }
  }

  static func insertUsage(_ db: Database, _ usage: ProviderUsage) throws {
    try db.execute(
      sql: """
        INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens, completion_tokens,
          cost_usd, cost_source, is_estimated, ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        usage.runId,
        usage.sessionId,
        usage.model,
        usage.promptTokens,
        usage.completionTokens,
        usage.costUSD,
        usage.costSource.rawValue,
        usage.isEstimated,
        usage.ts,
      ]
    )
  }

  static func insertOutbox(_ db: Database, runId: Int64, chunk: OutboxChunk, now: Date) throws {
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
          payload_hash, status, created_ts)
        VALUES (?, ?, ?, ?, ?, ?, 'PENDING', ?)
        """,
      arguments: [
        runId,
        chunk.stepIndex,
        chunk.chatId,
        "\(runId):\(chunk.stepIndex)",
        chunk.payload,
        chunk.payloadHash,
        now,
      ]
    )
  }

  // Deterministic-within-process content fingerprint; the UNIQUE `dedup_key` is what actually
  // dedups. Replaced by `ContentHash.fnv1a` (stable across processes) in Task 5.
  static func hash(_ text: String) -> String { String(text.hashValue) }
}
