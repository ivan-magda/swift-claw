import ClawCore
import Foundation
import Testing

@testable import ClawData

@Suite struct OutboxStoreTests {
  private struct Fixture {
    let outbox: OutboxStoreGRDB
    let runs: RunStoreGRDB
    let sessionId: Int64
    let runId: Int64
  }

  private func fixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 42),
        chatId: 42,
        userId: 42,
        text: "seed",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    return Fixture(
      outbox: OutboxStoreGRDB(writer: queue),
      runs: RunStoreGRDB(writer: queue),
      sessionId: sessionId,
      runId: runId
    )
  }

  @Test func claimIsIdempotentOnTheDeterministicKey() throws {
    // given
    let env = try fixture()

    // when — the same run_id:step_index claimed twice
    let first = try env.outbox.claimOutbound(
      runId: env.runId,
      stepIndex: 0,
      chatId: 42,
      payload: "p",
      payloadHash: "h"
    )
    let second = try env.outbox.claimOutbound(
      runId: env.runId,
      stepIndex: 0,
      chatId: 42,
      payload: "p",
      payloadHash: "h"
    )

    // then — INSERT OR IGNORE dedups; one PENDING row
    #expect(first)
    #expect(second == false)
    #expect(try env.outbox.pendingOutbound().count == 1)
  }

  @Test func markSentRemovesRowFromPending() throws {
    // given
    let env = try fixture()
    let claimed = try env.outbox.claimOutbound(
      runId: env.runId,
      stepIndex: 0,
      chatId: 42,
      payload: "p",
      payloadHash: "h"
    )
    #expect(claimed)

    // when
    try env.outbox.markSent(
      runId: env.runId,
      stepIndex: 0,
      telegramMessageId: 555,
      now: Date()
    )

    // then
    #expect(try env.outbox.pendingOutbound().isEmpty)
  }

  @Test func activeClaimOnlyInsertsForRunningRun() throws {
    // given
    let env = try fixture()

    // when / then
    #expect(
      try env.outbox.claimOutboundIfRunActive(
        runId: env.runId,
        stepIndex: 0,
        chatId: 42,
        payload: "pending",
        payloadHash: "p"
      ) == false
    )
    _ = try #require(try env.runs.pickUp(runId: env.runId, now: Date()))
    #expect(
      try env.outbox.claimOutboundIfRunActive(
        runId: env.runId,
        stepIndex: 0,
        chatId: 42,
        payload: "running",
        payloadHash: "r"
      )
    )
    _ = try env.runs.cancelActiveRun(
      sessionId: env.sessionId,
      reason: .cancelled,
      now: Date()
    )
    #expect(
      try env.outbox.claimOutboundIfRunActive(
        runId: env.runId,
        stepIndex: 1,
        chatId: 42,
        payload: "cancelled",
        payloadHash: "c"
      ) == false
    )
  }
}
