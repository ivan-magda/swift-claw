import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct RunStoreTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let sessions: SessionMessageStoreGRDB
    let runs: RunStoreGRDB
    let usage: UsageStoreGRDB
    let outbox: OutboxStoreGRDB
    let sessionId: Int64
  }

  private func fixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let sessionId = try sessions.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 42),
      now: Date()
    )
    return Fixture(
      queue: queue,
      sessions: sessions,
      runs: RunStoreGRDB(writer: queue),
      usage: UsageStoreGRDB(writer: queue),
      outbox: OutboxStoreGRDB(writer: queue),
      sessionId: sessionId
    )
  }

  private func usage(runId: Int64, sessionId: Int64) -> ProviderUsage {
    ProviderUsage(
      runId: runId,
      sessionId: sessionId,
      model: "m",
      promptTokens: 10,
      completionTokens: 20,
      costUSD: 0.001,
      costSource: .heuristic,
      isEstimated: true,
      ts: Date()
    )
  }

  @Test func commitAssistantTurnWritesMessageDoneUsageAndOutboxTogether() throws {
    // given
    let env = try fixture()
    let runId = try env.runs.createRun(sessionId: env.sessionId, now: Date())
    let turn = AssistantTurn(
      runId: runId,
      sessionId: env.sessionId,
      chatId: 42,
      content: "answer",
      usage: usage(runId: runId, sessionId: env.sessionId),
      chunks: [OutboxChunk(stepIndex: 0, chatId: 42, payload: "answer", payloadHash: "h")]
    )

    // when
    try env.runs.commitAssistantTurn(turn, now: Date())

    // then — assistant message persisted, run DONE, usage + one PENDING outbox row
    let history = try env.sessions.loadRecentMessages(sessionId: env.sessionId, limit: 10)
    #expect(
      history.contains(StoredMessage(role: .assistant, content: "answer", provenance: .trusted))
    )
    let state = try #require(
      try env.queue.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
      }
    )
    #expect(state == RunState.done.rawValue)
    #expect(try env.outbox.pendingOutbound().count == 1)
    let (tokens, _) = try env.usage.todayTokensAndCost(now: Date())
    #expect(tokens == 30)
  }

  @Test func reconcileFlipsRunningToFailedAndEnqueuesDegradationWhenNothingDelivered() throws {
    // given — a run left RUNNING with no outbox row (the crash-mid-call window)
    let env = try fixture()
    let runId = try env.runs.createRun(sessionId: env.sessionId, now: Date())

    // when
    let replies = try env.runs.reconcileRunsAtBoot(now: Date(), degradationText: "didn't finish")

    // then
    let state = try #require(
      try env.queue.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
      }
    )
    #expect(state == RunState.failed.rawValue)
    #expect(replies == [DegradationReply(chatId: 42, runId: runId, text: "didn't finish")])
    #expect(try env.outbox.pendingOutbound().count == 1)  // degradation reply enqueued
  }

  @Test func reconcileDoesNotEnqueueWhenARunAlreadyDelivered() throws {
    // given — a RUNNING run that already has an outbox row (reply was committed pre-crash)
    let env = try fixture()
    let runId = try env.runs.createRun(sessionId: env.sessionId, now: Date())
    _ = try env.outbox.claimOutbound(
      runId: runId,
      stepIndex: 0,
      chatId: 42,
      payload: "x",
      payloadHash: "h"
    )

    // when
    let replies = try env.runs.reconcileRunsAtBoot(now: Date(), degradationText: "didn't finish")

    // then — flipped to FAILED but no new degradation reply
    #expect(replies.isEmpty)
  }

  @Test func commitAssistantTurnRollsBackEntirelyWhenTheOutboxInsertAborts() throws {
    // given — a run, plus a trigger that aborts the outbox INSERT mid-commit
    let env = try fixture()
    let runId = try env.runs.createRun(sessionId: env.sessionId, now: Date())
    try env.queue.write { db in
      try db.execute(
        sql:
          "CREATE TRIGGER boom BEFORE INSERT ON outbound_deliveries BEGIN SELECT RAISE(ABORT, 'boom'); END"
      )
    }
    let turn = AssistantTurn(
      runId: runId,
      sessionId: env.sessionId,
      chatId: 42,
      content: "answer",
      usage: usage(runId: runId, sessionId: env.sessionId),
      chunks: [OutboxChunk(stepIndex: 0, chatId: 42, payload: "answer", payloadHash: "h")]
    )

    // when / then — the commit throws and writes NOTHING: no assistant message, run still RUNNING,
    // no provider_usage (F6 atomicity — all four side effects share one transaction)
    #expect(throws: (any Error).self) { try env.runs.commitAssistantTurn(turn, now: Date()) }
    let assistantCount = try #require(
      try env.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE role = 'assistant'")
      }
    )
    let state = try #require(
      try env.queue.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
      }
    )
    let usageCount = try #require(
      try env.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage")
      }
    )
    #expect(assistantCount == 0)
    #expect(state == RunState.running.rawValue)  // NOT flipped to DONE
    #expect(usageCount == 0)
  }
}
