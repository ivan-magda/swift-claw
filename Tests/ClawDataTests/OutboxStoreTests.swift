import ClawCore
import Foundation
import Testing

@testable import ClawData

@Suite struct OutboxStoreTests {
  private func fixture() throws -> (OutboxStoreGRDB, Int64) {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let sessionId = try sessions.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 42),
      now: Date()
    )
    let runId = try RunStoreGRDB(writer: queue).createRun(sessionId: sessionId, now: Date())
    return (OutboxStoreGRDB(writer: queue), runId)
  }

  @Test func claimIsIdempotentOnTheDeterministicKey() throws {
    // given
    let (outbox, runId) = try fixture()

    // when — the same run_id:step_index claimed twice
    let first = try outbox.claimOutbound(
      runId: runId,
      stepIndex: 0,
      chatId: 42,
      payload: "p",
      payloadHash: "h"
    )
    let second = try outbox.claimOutbound(
      runId: runId,
      stepIndex: 0,
      chatId: 42,
      payload: "p",
      payloadHash: "h"
    )

    // then — INSERT OR IGNORE dedups; one PENDING row
    #expect(first)
    #expect(second == false)
    #expect(try outbox.pendingOutbound().count == 1)
  }

  @Test func markSentRemovesRowFromPending() throws {
    // given
    let (outbox, runId) = try fixture()
    let claimed = try outbox.claimOutbound(
      runId: runId,
      stepIndex: 0,
      chatId: 42,
      payload: "p",
      payloadHash: "h"
    )
    #expect(claimed)

    // when
    try outbox.markSent(runId: runId, stepIndex: 0, telegramMessageId: 555, now: Date())

    // then
    #expect(try outbox.pendingOutbound().isEmpty)
  }
}
