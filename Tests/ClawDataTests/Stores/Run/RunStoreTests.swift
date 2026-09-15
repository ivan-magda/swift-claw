import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct RunStoreTests {
  private struct Fixture {
    let queue: DatabaseQueue

    let sessions: SessionMessageStoreGRDB
    let runs: RunStoreGRDB
    let usage: UsageStoreGRDB
    let outbox: OutboxStoreGRDB

    let sessionID: Int64
    let seedRunID: Int64
  }

  private func fixture() throws -> Fixture {
    let queue = try TestDatabase.make()
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: 42),
        chatID: 42,
        userID: 42,
        text: "hi",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionID = try #require(claim.sessionID)
    let seedRunID = try #require(claim.runID)
    return Fixture(
      queue: queue,
      sessions: sessions,
      runs: RunStoreGRDB(writer: queue),
      usage: UsageStoreGRDB(writer: queue),
      outbox: OutboxStoreGRDB(writer: queue),
      sessionID: sessionID,
      seedRunID: seedRunID
    )
  }

  private func usage(runID: Int64, sessionID: Int64) -> ProviderUsage {
    makeProviderUsage(runID: runID, sessionID: sessionID, completionTokens: 20, isEstimated: true)
  }

  @Test
  func pickUpMovesPendingRunToRunningOnceAndReturnsTheOrigin() throws {
    // given
    let env = try fixture()

    // when
    let first = try env.runs.pickUp(runID: env.seedRunID, now: Date())
    let second = try env.runs.pickUp(runID: env.seedRunID, now: Date())

    // then — the origin rides the pickup read; the not-PENDING guard is nil (preamble dev. 3)
    #expect(first == .interactive)  // v6 default backfill
    #expect(second == nil)
  }

  @Test
  func pickUpReturnsTheScheduledOrigin() throws {
    // given
    let env = try fixture()
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE runs SET origin = 'scheduled' WHERE id = ?",
        arguments: [env.seedRunID]
      )
    }

    // when / then
    #expect(try env.runs.pickUp(runID: env.seedRunID, now: Date()) == .scheduled)
  }

  @Test
  func assistantCommitAfterSupersedeRecordsUsageOnly() throws {
    // given
    let env = try fixture()
    _ = try CommandStoreGRDB(writer: env.queue).applyNew(
      updateID: 100,
      sessionKey: SessionKey.telegramDM(chatID: 42),
      now: Date()
    )
    let turn = AssistantTurn(
      runID: env.seedRunID,
      sessionID: env.sessionID,
      chatID: 42,
      content: "answer",
      usage: usage(runID: env.seedRunID, sessionID: env.sessionID),
      chunks: [OutboxChunk(stepIndex: 0, chatID: 42, payload: "answer", payloadHash: "h")]
    )

    // when
    let result = try env.runs.commitAssistantTurn(turn, now: Date())
    try env.runs.failRun(runID: env.seedRunID, cause: .providerFailure, now: Date())

    // then
    let state = try #require(
      try env.queue.read { db in
        try String.fetchOne(
          db,
          sql: "SELECT state FROM runs WHERE id = ?",
          arguments: [env.seedRunID]
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

  @Test
  func commitAssistantTurnWritesMessageDoneUsageAndOutboxTogether() throws {
    // given
    let env = try fixture()
    let runID = env.seedRunID
    _ = try #require(try env.runs.pickUp(runID: runID, now: Date()))
    let turn = AssistantTurn(
      runID: runID,
      sessionID: env.sessionID,
      chatID: 42,
      content: "answer",
      usage: usage(runID: runID, sessionID: env.sessionID),
      chunks: [OutboxChunk(stepIndex: 0, chatID: 42, payload: "answer", payloadHash: "h")]
    )

    // when
    let result = try env.runs.commitAssistantTurn(turn, now: Date())

    // then
    let assistantCount = try #require(
      try env.queue.read { db in
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM messages WHERE run_id = ? AND role = 'assistant'",
          arguments: [runID]
        )
      }
    )
    #expect(assistantCount == 1)
    let state = try #require(
      try env.queue.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runID])
      }
    )
    #expect(state == RunState.done.rawValue)
    #expect(result == .committed)
    #expect(try env.outbox.pendingOutbound().count == 1)
    let (tokens, _) = try env.usage.todayTokensAndCost(now: Date())
    #expect(tokens == 30)
  }

  @Test
  func reconcileFlipsPendingAndRunningToFailed() throws {
    // given
    let env = try fixture()
    let pendingRunID = env.seedRunID
    let runningClaim = try env.sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: 2,
        sessionKey: SessionKey.telegramDM(chatID: 42),
        chatID: 42,
        userID: 42,
        text: "running",
        isEdited: false,
        ts: Date()
      )
    )
    let runningRunID = try #require(runningClaim.runID)
    _ = try #require(try env.runs.pickUp(runID: runningRunID, now: Date()))

    // when
    let replies = try env.runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "didn't finish",
      heartbeatNoticeChatID: nil
    )

    // then
    let states = try env.queue.read { db in
      try String.fetchAll(db, sql: "SELECT state FROM runs ORDER BY id ASC")
    }
    #expect(states == [RunState.failed.rawValue, RunState.failed.rawValue])
    #expect(Set(replies.map(\.runID)) == Set([pendingRunID, runningRunID]))
    #expect(try env.outbox.pendingOutbound().count == 2)
  }

  @Test
  func reconcileDoesNotEnqueueWhenARunAlreadyDelivered() throws {
    // given
    let env = try fixture()
    let runID = env.seedRunID
    _ = try #require(try env.runs.pickUp(runID: runID, now: Date()))
    try OutboxFixture.seedLegacyRunDelivery(
      in: env.queue,
      runID: runID,
      chunk: OutboxChunk(stepIndex: 0, chatID: 42, payload: "x", payloadHash: "h"),
      deliveryKey: OutboxDedupKey.make(runID: runID, stepIndex: 0)
    )
    try env.outbox.markSent(
      deliveryKey: OutboxDedupKey.make(runID: runID, stepIndex: 0),
      telegramMessageID: 1001,
      now: Date()
    )

    // when
    let replies = try env.runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "didn't finish",
      heartbeatNoticeChatID: nil
    )

    // then
    #expect(replies.isEmpty)
    let state = try #require(
      try env.queue.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runID])
      }
    )
    #expect(state == RunState.failed.rawValue)
  }

  @Test
  func commitAssistantTurnRollsBackEntirelyWhenTheOutboxInsertAborts() throws {
    // given
    let env = try fixture()
    let runID = env.seedRunID
    _ = try #require(try env.runs.pickUp(runID: runID, now: Date()))
    try env.queue.write { db in
      try db.execute(
        sql: """
        CREATE TRIGGER boom BEFORE INSERT ON outbound_deliveries \
        BEGIN SELECT RAISE(ABORT, 'boom'); END
        """
      )
    }
    let turn = AssistantTurn(
      runID: runID,
      sessionID: env.sessionID,
      chatID: 42,
      content: "answer",
      usage: usage(runID: runID, sessionID: env.sessionID),
      chunks: [OutboxChunk(stepIndex: 0, chatID: 42, payload: "answer", payloadHash: "h")]
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
        try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runID])
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

  // MARK: - Usage Fixture Distinctness

  @Test
  func twoUnnamedFixtureRowsBothPersistRatherThanCollapsingIntoOne() throws {
    // given — a running run, and two spend rows built without naming their calls. Rows are unique
    // on the call identity and the insert resolves a conflict by doing nothing, so a shared fixture
    // default would drop the second row here with no error and leave the suite green.
    let env = try fixture()
    _ = try #require(try env.runs.pickUp(runID: env.seedRunID, now: Date()))

    // when
    try env.usage.recordUsage(makeProviderUsage(runID: env.seedRunID, sessionID: env.sessionID))
    try env.usage.recordUsage(makeProviderUsage(runID: env.seedRunID, sessionID: env.sessionID))

    // then
    #expect(try usageRowCount(env) == 2)
  }

  // MARK: - Terminal Usage Idempotency

  @Test
  func aLateTerminalRowIsRecordedEvenWhenAnEarlierRoundAlreadySpent() throws {
    // given — a cancelled run whose tool loop already recorded round one's spend mid-flight. The
    // run-wide guard this replaces refused exactly this row, silently dropping the terminal
    // round's spend for every run whose loop got past its first round.
    let env = try fixture()
    _ = try #require(try env.runs.pickUp(runID: env.seedRunID, now: Date()))
    try env.usage.recordUsage(
      makeProviderUsage(
        runID: env.seedRunID,
        sessionID: env.sessionID,
        callID: "call-round-1",
        promptTokens: 10,
        completionTokens: 20,
        costUSD: 0.004
      )
    )
    _ = try CommandStoreGRDB(writer: env.queue).applyStop(
      updateID: 100,
      sessionKey: SessionKey.telegramDM(chatID: 42),
      now: Date()
    )

    // when — the terminal round's commit arrives after the cancellation
    let result = try env.runs.commitAssistantTurn(
      terminalTurn(env, callID: "call-round-2", promptTokens: 7, completionTokens: 3, costUSD: 0.5),
      now: Date()
    )

    // then
    #expect(result == .usageRecordedAfterTerminal)
    #expect(try usageRowCount(env) == 2)
  }

  @Test
  func recordingALateRowRecomputesTheRunTotalsFromEveryStoredRow() throws {
    // given
    let env = try fixture()
    _ = try #require(try env.runs.pickUp(runID: env.seedRunID, now: Date()))
    try env.usage.recordUsage(
      makeProviderUsage(
        runID: env.seedRunID,
        sessionID: env.sessionID,
        callID: "call-round-1",
        promptTokens: 10,
        completionTokens: 20,
        costUSD: 0.004
      )
    )
    _ = try CommandStoreGRDB(writer: env.queue).applyStop(
      updateID: 100,
      sessionKey: SessionKey.telegramDM(chatID: 42),
      now: Date()
    )

    // when
    _ = try env.runs.commitAssistantTurn(
      terminalTurn(env, callID: "call-round-2", promptTokens: 7, completionTokens: 3, costUSD: 0.5),
      now: Date()
    )

    // then — the totals are the sum of both rounds, not the late row overwriting the first
    let totals = try runTotals(env)
    #expect(totals.input == 17)
    #expect(totals.output == 23)
    #expect(abs(totals.cost - 0.504) < 1e-9)
  }

  @Test
  func aCompletedRunsTotalsEqualTheSumOfEveryRoundItRecorded() throws {
    // given — a live multi-round loop: the intermediate round's row is already stored when the
    // terminal round commits
    let env = try fixture()
    _ = try #require(try env.runs.pickUp(runID: env.seedRunID, now: Date()))
    try env.usage.recordUsage(
      makeProviderUsage(
        runID: env.seedRunID,
        sessionID: env.sessionID,
        callID: "call-round-1",
        promptTokens: 10,
        completionTokens: 20,
        costUSD: 0.004
      )
    )

    // when
    _ = try env.runs.commitAssistantTurn(
      terminalTurn(env, callID: "call-round-2", promptTokens: 7, completionTokens: 3, costUSD: 0.5),
      now: Date()
    )

    // then — the run's totals mean the same thing here as after a late commit: what the run spent,
    // not what its last round spent
    let totals = try runTotals(env)
    #expect(totals.input == 17)
    #expect(totals.output == 23)
    #expect(abs(totals.cost - 0.504) < 1e-9)
  }

  @Test
  func aDegradedRunsTotalsEqualTheSumOfEveryRoundItRecorded() throws {
    // given
    let env = try fixture()
    _ = try #require(try env.runs.pickUp(runID: env.seedRunID, now: Date()))
    try env.usage.recordUsage(
      makeProviderUsage(
        runID: env.seedRunID,
        sessionID: env.sessionID,
        callID: "call-round-1",
        promptTokens: 10,
        completionTokens: 20,
        costUSD: 0.004
      )
    )

    // when
    _ = try env.runs.commitDegradedTurn(
      degradedTurn(env, callID: "call-round-2", promptTokens: 7, completionTokens: 3, costUSD: 0.5),
      now: Date()
    )

    // then
    let totals = try runTotals(env)
    #expect(totals.input == 17)
    #expect(totals.output == 23)
    #expect(abs(totals.cost - 0.504) < 1e-9)
  }

  @Test
  func aDegradedCommitWhoseUsageRowAlreadyLandedLeavesTheTotalsAlone() throws {
    // given — the round already recorded its row; the degradation commit re-presents the SAME call
    // under an estimate. The insert conflicts and writes nothing, so the totals it computes must
    // still describe the rows the run owns rather than the estimate that lost.
    let env = try fixture()
    _ = try #require(try env.runs.pickUp(runID: env.seedRunID, now: Date()))
    try env.usage.recordUsage(
      makeProviderUsage(
        runID: env.seedRunID,
        sessionID: env.sessionID,
        callID: "call-round-1",
        promptTokens: 10,
        completionTokens: 20,
        costUSD: 0.004
      )
    )

    // when
    _ = try env.runs.commitDegradedTurn(
      degradedTurn(
        env,
        callID: "call-round-1",
        promptTokens: 999,
        completionTokens: 999,
        costUSD: 9
      ),
      now: Date()
    )

    // then
    #expect(try usageRowCount(env) == 1)
    let totals = try runTotals(env)
    #expect(totals.input == 10)
    #expect(totals.output == 20)
    #expect(abs(totals.cost - 0.004) < 1e-9)
  }

  @Test
  func replayingTheTerminalCommitChangesNeitherTotalsNorDayBudgets() throws {
    // given — a cancelled run whose terminal commit already landed
    let env = try fixture()
    _ = try #require(try env.runs.pickUp(runID: env.seedRunID, now: Date()))
    _ = try CommandStoreGRDB(writer: env.queue).applyStop(
      updateID: 100,
      sessionKey: SessionKey.telegramDM(chatID: 42),
      now: Date()
    )
    let turn = terminalTurn(
      env,
      callID: "call-round-1",
      promptTokens: 7,
      completionTokens: 3,
      costUSD: 0.5
    )
    #expect(try env.runs.commitAssistantTurn(turn, now: Date()) == .usageRecordedAfterTerminal)
    let totalsAfterFirst = try runTotals(env)

    // when — the identical commit is re-presented
    let replay = try env.runs.commitAssistantTurn(turn, now: Date())

    // then — the unique key absorbs it: no row, no total change, no day debit
    #expect(replay == .ignored)
    #expect(try usageRowCount(env) == 1)
    let totalsAfterReplay = try runTotals(env)
    #expect(totalsAfterReplay.input == totalsAfterFirst.input)
    #expect(totalsAfterReplay.output == totalsAfterFirst.output)
    #expect(totalsAfterReplay.cost == totalsAfterFirst.cost)
    let (tokens, cost) = try env.usage.todayTokensAndCost(now: Date())
    #expect(tokens == 10)
    #expect(abs(cost - 0.5) < 1e-9)
  }

  @Test
  func aLateRowIsRecordedAfterSupersessionToo() throws {
    // given — supersession is the other terminal state a late commit can land against
    let env = try fixture()
    _ = try #require(try env.runs.pickUp(runID: env.seedRunID, now: Date()))
    try env.usage.recordUsage(
      makeProviderUsage(
        runID: env.seedRunID,
        sessionID: env.sessionID,
        callID: "call-round-1",
        promptTokens: 10,
        completionTokens: 20,
        costUSD: 0.004
      )
    )
    _ = try CommandStoreGRDB(writer: env.queue).applyNew(
      updateID: 100,
      sessionKey: SessionKey.telegramDM(chatID: 42),
      now: Date()
    )

    // when
    let result = try env.runs.commitAssistantTurn(
      terminalTurn(env, callID: "call-round-2", promptTokens: 7, completionTokens: 3, costUSD: 0.5),
      now: Date()
    )

    // then
    #expect(result == .usageRecordedAfterTerminal)
    #expect(try usageRowCount(env) == 2)
    let totals = try runTotals(env)
    #expect(totals.input == 17)
    #expect(totals.output == 23)
  }

  @Test
  func corruptOriginFailsClosedAtPickup() throws {
    // given — a PENDING run whose origin left the vocabulary
    let queue = try TestDatabase.make()
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: 42),
        chatID: 42,
        userID: 42,
        text: "hello",
        isEdited: false,
        ts: Date(timeIntervalSince1970: 1)
      )
    )
    let runID = try #require(claim.runID)
    try queue.write { db in
      try db.execute(sql: "UPDATE runs SET origin = 'webhook' WHERE id = ?", arguments: [runID])
    }

    // when / then — pickUp throws and the transaction rolls back: the run stays PENDING
    #expect(throws: StoreError.self) {
      _ = try runs.pickUp(runID: runID, now: Date(timeIntervalSince1970: 10))
    }
    let state = try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runID])
    }
    #expect(state == RunState.pending.rawValue)
  }
}

// MARK: - Terminal Usage Helpers

private extension RunStoreTests {
  /// The turn a tool loop's terminal round commits, named by the call it accounts for.
  private func terminalTurn(
    _ env: Fixture,
    callID: String,
    promptTokens: Int,
    completionTokens: Int,
    costUSD: Double
  ) -> AssistantTurn {
    AssistantTurn(
      runID: env.seedRunID,
      sessionID: env.sessionID,
      chatID: 42,
      content: "answer",
      usage: makeProviderUsage(
        runID: env.seedRunID,
        sessionID: env.sessionID,
        callID: callID,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        costUSD: costUSD
      ),
      chunks: [OutboxChunk(stepIndex: 0, chatID: 42, payload: "answer", payloadHash: "h")]
    )
  }

  /// The turn a tool loop's terminal round commits when it degrades, named by the call it accounts
  /// for.
  private func degradedTurn(
    _ env: Fixture,
    callID: String,
    promptTokens: Int,
    completionTokens: Int,
    costUSD: Double
  ) -> DegradedTurn {
    DegradedTurn(
      runID: env.seedRunID,
      sessionID: env.sessionID,
      chatID: 42,
      usage: makeProviderUsage(
        runID: env.seedRunID,
        sessionID: env.sessionID,
        callID: callID,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        costUSD: costUSD
      ),
      chunk: OutboxChunk(stepIndex: 0, chatID: 42, payload: "degraded", payloadHash: "h"),
      cause: .providerFailure
    )
  }

  private func usageRowCount(_ env: Fixture) throws -> Int {
    try env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage") ?? -1
    }
  }

  private func runTotals(_ env: Fixture) throws -> (input: Int, output: Int, cost: Double) {
    let row = try #require(
      try env.queue.read { db in
        try Row.fetchOne(
          db,
          sql: "SELECT input_tokens, output_tokens, cost_usd FROM runs WHERE id = ?",
          arguments: [env.seedRunID]
        )
      }
    )
    return (row["input_tokens"], row["output_tokens"], row["cost_usd"])
  }
}
