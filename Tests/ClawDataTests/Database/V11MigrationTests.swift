import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V11MigrationTests {
  @Test func vElevenPreservesPendingOutboxAndConstrainsOriginCall() throws {
    // given
    let fixture = try CoderStoreFixture(schemaVersion: "v10")
    let outbox = OutboxStoreGRDB(writer: fixture.queue)
    let legacy = try #require(try outbox.pendingOutbound().first)
    // when
    try ClawDatabase.migrate(fixture.queue)
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
