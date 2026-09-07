import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V11MigrationTests {
  @Test func vElevenPreservesPendingOutboxAndConstrainsOriginCall() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedLegacyOutbox(queue)
    let outbox = OutboxStoreGRDB(writer: queue)
    let legacy = try #require(try outbox.pendingOutbound().first)
    // when
    try ClawDatabase.migrate(queue)
    let fixture = try CoderStoreFixture(queue: queue)
    let id = try fixture.admittedID()
    // then
    let preserved = try #require(try outbox.pendingOutbound().first)
    #expect(preserved.runId == legacy.runId)
    #expect(preserved.payload == legacy.payload)
    #expect(preserved.stepIndex == legacy.stepIndex)
    #expect(preserved.approvalId == legacy.approvalId)
    #expect(throws: DatabaseError.self) {
      try fixture.queue.write { db in
        try db.execute(
          sql: """
            INSERT INTO coder_jobs(id, origin_run_id, origin_session_id, requester_user_id,
              chat_id, tool_call_id, approval_id, prepared_json, state, slot_reserved,
              process_ownership, created_ts, updated_ts)
            SELECT ?, origin_run_id, origin_session_id, requester_user_id, chat_id,
              tool_call_id, approval_id, prepared_json, state, slot_reserved,
              process_ownership, created_ts, updated_ts FROM coder_jobs WHERE id = ?
            """,
          arguments: [UUID().uuidString, id.uuidString]
        )
      }
    }
  }
}

// MARK: - Legacy Fixture

private extension V11MigrationTests {
  static func seedLegacyOutbox(_ queue: DatabaseQueue) throws {
    try ClawDatabase.migrator.migrate(queue, upTo: "v10")
    try queue.write { db in
      try db.execute(
        sql: "INSERT INTO sessions(session_key, created_ts, updated_ts) VALUES (?, ?, ?)",
        arguments: [SessionKey.telegramDM(chatId: 42), Date(), Date()]
      )
      let sessionId = db.lastInsertedRowID
      try db.execute(
        sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (?, ?, ?, ?)",
        arguments: [sessionId, RunState.done.rawValue, Date(), Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
            payload_hash, status, created_ts)
          VALUES (?, 0, 42, 'legacy-coder-notice', 'pending notice', 'legacy-hash', 'PENDING', ?)
          """,
        arguments: [db.lastInsertedRowID, Date()]
      )
    }
  }
}
