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
    let seedRunId: Int64
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
        text: "hi",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionId = try #require(claim.sessionId)
    let seedRunId = try #require(claim.runId)
    return Fixture(
      queue: queue,
      sessions: sessions,
      runs: RunStoreGRDB(writer: queue),
      usage: UsageStoreGRDB(writer: queue),
      outbox: OutboxStoreGRDB(writer: queue),
      sessionId: sessionId,
      seedRunId: seedRunId
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

  @Test func pickUpMovesPendingRunToRunningOnceAndReturnsTheOrigin() throws {
    // given
    let env = try fixture()

    // when
    let first = try env.runs.pickUp(runId: env.seedRunId, now: Date())
    let second = try env.runs.pickUp(runId: env.seedRunId, now: Date())

    // then — the origin rides the pickup read; the not-PENDING guard is nil (preamble dev. 3)
    #expect(first == .interactive)  // v6 default backfill
    #expect(second == nil)
  }

  @Test func pickUpReturnsTheScheduledOrigin() throws {
    // given
    let env = try fixture()
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE runs SET origin = 'scheduled' WHERE id = ?",
        arguments: [env.seedRunId]
      )
    }

    // when / then
    #expect(try env.runs.pickUp(runId: env.seedRunId, now: Date()) == .scheduled)
  }

  @Test func cancelActiveRunOnlyCancelsRunningRun() throws {
    // given
    let env = try fixture()
    #expect(
      try env.runs.cancelActiveRun(
        sessionId: env.sessionId,
        reason: .cancelled,
        now: Date()
      ) == nil
    )
    _ = try #require(try env.runs.pickUp(runId: env.seedRunId, now: Date()))

    // when
    let cancelled = try env.runs.cancelActiveRun(
      sessionId: env.sessionId,
      reason: .cancelled,
      now: Date()
    )

    // then
    #expect(cancelled == env.seedRunId)
    let state = try #require(
      try env.queue.read { db in
        try String.fetchOne(
          db,
          sql: "SELECT state FROM runs WHERE id = ?",
          arguments: [env.seedRunId]
        )
      }
    )
    #expect(state == RunState.cancelled.rawValue)
  }

  @Test func supersedeSessionRunsTerminatesRunningAndQueuedRuns() throws {
    // given
    let env = try fixture()
    _ = try #require(try env.runs.pickUp(runId: env.seedRunId, now: Date()))
    let queued = try env.sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 2,
        sessionKey: SessionKey.telegramDM(chatId: 42),
        chatId: 42,
        userId: 42,
        text: "queued",
        isEdited: false,
        ts: Date()
      )
    )
    let queuedRunId = try #require(queued.runId)

    // when
    let superseded = try env.runs.supersedeSessionRuns(sessionId: env.sessionId, now: Date())

    // then
    #expect(superseded == [env.seedRunId, queuedRunId])
    let states = try env.queue.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT state FROM runs WHERE id IN (?, ?) ORDER BY id ASC",
        arguments: [env.seedRunId, queuedRunId]
      )
    }
    #expect(states == [RunState.superseded.rawValue, RunState.superseded.rawValue])
    #expect(try env.runs.pickUp(runId: queuedRunId, now: Date()) == nil)
  }

  @Test func assistantCommitAfterSupersedeRecordsUsageOnly() throws {
    // given
    let env = try fixture()
    _ = try env.runs.supersedeSessionRuns(sessionId: env.sessionId, now: Date())
    let turn = AssistantTurn(
      runId: env.seedRunId,
      sessionId: env.sessionId,
      chatId: 42,
      content: "answer",
      usage: usage(runId: env.seedRunId, sessionId: env.sessionId),
      chunks: [OutboxChunk(stepIndex: 0, chatId: 42, payload: "answer", payloadHash: "h")]
    )

    // when
    let result = try env.runs.commitAssistantTurn(turn, now: Date())
    try env.runs.failRun(runId: env.seedRunId, now: Date())

    // then
    let state = try #require(
      try env.queue.read { db in
        try String.fetchOne(
          db,
          sql: "SELECT state FROM runs WHERE id = ?",
          arguments: [env.seedRunId]
        )
      }
    )
    #expect(state == RunState.superseded.rawValue)
    #expect(try env.outbox.pendingOutbound().isEmpty)
    let usageCount = try #require(
      try env.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage")
      }
    )
    let assistantCount = try #require(
      try env.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE role = 'assistant'")
      }
    )
    #expect(result == .usageRecordedAfterTerminal)
    #expect(usageCount == 1)
    #expect(assistantCount == 0)
  }

  @Test func commitAssistantTurnWritesMessageDoneUsageAndOutboxTogether() throws {
    // given
    let env = try fixture()
    let runId = env.seedRunId
    _ = try #require(try env.runs.pickUp(runId: runId, now: Date()))
    let turn = AssistantTurn(
      runId: runId,
      sessionId: env.sessionId,
      chatId: 42,
      content: "answer",
      usage: usage(runId: runId, sessionId: env.sessionId),
      chunks: [OutboxChunk(stepIndex: 0, chatId: 42, payload: "answer", payloadHash: "h")]
    )

    // when
    let result = try env.runs.commitAssistantTurn(turn, now: Date())

    // then
    let assistantCount = try #require(
      try env.queue.read { db in
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM messages WHERE run_id = ? AND role = 'assistant'",
          arguments: [runId]
        )
      }
    )
    #expect(assistantCount == 1)
    let state = try #require(
      try env.queue.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
      }
    )
    #expect(state == RunState.done.rawValue)
    #expect(result == .committed)
    #expect(try env.outbox.pendingOutbound().count == 1)
    let (tokens, _) = try env.usage.todayTokensAndCost(now: Date())
    #expect(tokens == 30)
  }

  @Test func reconcileFlipsPendingAndRunningToFailed() throws {
    // given
    let env = try fixture()
    let pendingRunId = env.seedRunId
    let runningClaim = try env.sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 2,
        sessionKey: SessionKey.telegramDM(chatId: 42),
        chatId: 42,
        userId: 42,
        text: "running",
        isEdited: false,
        ts: Date()
      )
    )
    let runningRunId = try #require(runningClaim.runId)
    _ = try #require(try env.runs.pickUp(runId: runningRunId, now: Date()))

    // when
    let replies = try env.runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "didn't finish",
      heartbeatNoticeChatId: nil
    )

    // then
    let states = try env.queue.read { db in
      try String.fetchAll(db, sql: "SELECT state FROM runs ORDER BY id ASC")
    }
    #expect(states == [RunState.failed.rawValue, RunState.failed.rawValue])
    #expect(Set(replies.map(\.runId)) == Set([pendingRunId, runningRunId]))
    #expect(try env.outbox.pendingOutbound().count == 2)
  }

  @Test func reconcileDoesNotEnqueueWhenARunAlreadyDelivered() throws {
    // given
    let env = try fixture()
    let runId = env.seedRunId
    _ = try #require(try env.runs.pickUp(runId: runId, now: Date()))
    _ = try env.outbox.claimOutbound(
      runId: runId,
      chunk: OutboxChunk(stepIndex: 0, chatId: 42, payload: "x", payloadHash: "h")
    )
    try env.outbox.markSent(runId: runId, stepIndex: 0, telegramMessageId: 1001, now: Date())

    // when
    let replies = try env.runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "didn't finish",
      heartbeatNoticeChatId: nil
    )

    // then
    #expect(replies.isEmpty)
    let state = try #require(
      try env.queue.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
      }
    )
    #expect(state == RunState.failed.rawValue)
  }

  @Test func commitAssistantTurnRollsBackEntirelyWhenTheOutboxInsertAborts() throws {
    // given
    let env = try fixture()
    let runId = env.seedRunId
    _ = try #require(try env.runs.pickUp(runId: runId, now: Date()))
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
    #expect(throws: (any Error).self) {
      _ = try env.runs.commitAssistantTurn(turn, now: Date())
    }
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

  @Test func corruptOriginFailsClosedAtPickup() throws {
    // given — a PENDING run whose origin left the vocabulary
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 42),
        chatId: 42,
        userId: 42,
        text: "hello",
        isEdited: false,
        ts: Date(timeIntervalSince1970: 1)
      )
    )
    let runId = try #require(claim.runId)
    try queue.write { db in
      try db.execute(sql: "UPDATE runs SET origin = 'webhook' WHERE id = ?", arguments: [runId])
    }

    // when / then — pickUp throws and the transaction rolls back: the run stays PENDING
    #expect(throws: StoreError.self) {
      _ = try runs.pickUp(runId: runId, now: Date(timeIntervalSince1970: 10))
    }
    let state = try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
    }
    #expect(state == RunState.pending.rawValue)
  }
}
