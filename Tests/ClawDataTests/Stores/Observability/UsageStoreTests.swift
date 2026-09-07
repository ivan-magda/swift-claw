import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct UsageStoreTests {
  @Test func todayTotalsSumTokensAndCostInTheUtcDay() throws {
    // given
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
    let usage = UsageStoreGRDB(writer: queue)
    let now = Date()
    try usage.recordUsage(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-1"),
        runId: runId,
        sessionId: sessionId,
        model: "m",
        promptTokens: 100,
        completionTokens: 50,
        costUSD: 0.0123,
        costSource: .providerReturned,
        isEstimated: false,
        ts: now
      )
    )

    // when
    let (tokens, cost) = try usage.todayTokensAndCost(now: now)

    // then
    #expect(tokens == 150)
    #expect(abs(cost - 0.0123) < 1e-9)
  }

  @Test func originFilteredTotalsSumOnlyJoinedOriginUsage() throws {
    // given — one interactive run and one scheduled run, each with usage recorded today
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let interactiveClaim = try sessions.claimAndPersistInbound(
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
    let scheduledClaim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 2,
        sessionKey: SessionKey.telegramDM(chatId: 43),
        chatId: 43,
        userId: 43,
        text: "seed",
        isEdited: false,
        ts: Date()
      )
    )
    let interactiveRunId = try #require(interactiveClaim.runId)
    let scheduledRunId = try #require(scheduledClaim.runId)
    try queue.write { db in
      try db.execute(
        sql: "UPDATE runs SET origin = 'scheduled' WHERE id = ?",
        arguments: [scheduledRunId]
      )
    }

    let usage = UsageStoreGRDB(writer: queue)
    let now = Date()
    try usage.recordUsage(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-interactive"),
        runId: interactiveRunId,
        sessionId: try #require(interactiveClaim.sessionId),
        model: "m",
        promptTokens: 100,
        completionTokens: 50,
        costUSD: 0.40,
        costSource: .providerReturned,
        isEstimated: false,
        ts: now
      )
    )
    try usage.recordUsage(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-scheduled"),
        runId: scheduledRunId,
        sessionId: try #require(scheduledClaim.sessionId),
        model: "m",
        promptTokens: 10,
        completionTokens: 5,
        costUSD: 1.25,
        costSource: .providerReturned,
        isEstimated: false,
        ts: now
      )
    )

    // A schedule parse: runless, and belonging to no learning operation either. Now that a
    // runless learning row does reach the proactive pool, this is the row that must not.
    try usage.recordUsage(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-runless"),
        runId: nil,
        sessionId: try #require(interactiveClaim.sessionId),
        model: "m",
        promptTokens: 6,
        completionTokens: 3,
        costUSD: 0.02,
        costSource: .providerReturned,
        isEstimated: false,
        ts: now
      )
    )

    // when — one query, one UTC-day-boundary evaluation (preamble deviation 2)
    let proactive = try usage.todayTokensAndCost(origins: [.scheduled, .heartbeat], now: now)
    let everything = try usage.todayTokensAndCost(now: now)
    let none = try usage.todayTokensAndCost(origins: [], now: now)

    // then — only the joined-origin usage is summed; the global total is untouched
    #expect(proactive.tokens == 15)
    #expect(abs(proactive.costUSD - 1.25) < 1e-9)
    #expect(everything.tokens == 174)
    #expect(none.tokens == 0)
    #expect(none.costUSD == 0)
  }

  @Test func todayTotalsCountOnlyTheCurrentUtcDayAcrossTheBoundary() throws {
    // given — a fixed UTC "now" at noon, its UTC day start, and a ~25h-old instant (previous day)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(
      utc.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 12, minute: 0, second: 0))
    )
    let dayStart = now.startOfUTCDay
    let previousDay = now.addingTimeInterval(-25 * 3600)

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
        ts: now
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    let usage = UsageStoreGRDB(writer: queue)

    // when — previous-day (excluded), exactly at the UTC day start (included via `>=`), and midday
    try usage.recordUsage(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-previous-day"),
        runId: runId,
        sessionId: sessionId,
        model: "m",
        promptTokens: 900,
        completionTokens: 99,
        costUSD: 5.0,
        costSource: .providerReturned,
        isEstimated: false,
        ts: previousDay
      )
    )
    try usage.recordUsage(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-day-start"),
        runId: runId,
        sessionId: sessionId,
        model: "m",
        promptTokens: 10,
        completionTokens: 0,
        costUSD: 0.005,
        costSource: .providerReturned,
        isEstimated: false,
        ts: dayStart
      )
    )
    try usage.recordUsage(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-midday"),
        runId: runId,
        sessionId: sessionId,
        model: "m",
        promptTokens: 100,
        completionTokens: 50,
        costUSD: 0.0123,
        costSource: .providerReturned,
        isEstimated: false,
        ts: now
      )
    )

    // then — only the two same-UTC-day rows are summed; the ~25h-old row is excluded
    let (tokens, cost) = try usage.todayTokensAndCost(now: now)
    #expect(tokens == 160)
    #expect(abs(cost - 0.0173) < 1e-9)
    #expect(try usage.costSourceMix(now: now) == [.providerReturned: 2])
  }

  // MARK: - Latest Prompt Usage

  @Test func latestPromptUsageReturnsTheNewestRow() throws {
    // given — two calls of one run; the later call carries the run's full context
    let env = try Self.fixture()
    try env.usage.recordUsage(
      Self.usage(callID: "call-1", runId: env.runId, sessionId: env.sessionId)
    )
    try env.usage.recordUsage(
      Self.usage(callID: "call-2", runId: env.runId, sessionId: env.sessionId, promptTokens: 44853)
    )

    // when
    let latest = try env.usage.latestPromptUsage()

    // then — the most recently recorded call, not the largest or the first
    #expect(latest?.promptTokens == 44853)
    #expect(latest?.runId == env.runId)
    #expect(latest?.isEstimated == false)
  }

  @Test func latestPromptUsageCarriesTheEstimateFlagOfAConservativeRow() throws {
    // given — a deadline/failure books an estimated row; its guess must not read as provider truth
    let env = try Self.fixture()
    try env.usage.recordUsage(
      Self.usage(
        callID: "call-degraded",
        runId: env.runId,
        sessionId: env.sessionId,
        promptTokens: 52012,
        isEstimated: true
      )
    )

    // when
    let latest = try env.usage.latestPromptUsage()

    // then
    #expect(latest?.promptTokens == 52012)
    #expect(latest?.isEstimated == true)
  }

  @Test func latestPromptUsageIsNilBeforeAnyCallWasRecorded() throws {
    // given
    let env = try Self.fixture()

    // when / then
    #expect(try env.usage.latestPromptUsage() == nil)
  }

  // MARK: - Call Idempotency

  @Test func recordingTheSameCallTwiceStoresOneRowAndDebitsTheDayOnce() throws {
    // given — the shape a commit retried after its first attempt already landed produces
    let env = try Self.fixture()
    let row = Self.usage(callID: "call-1", runId: env.runId, sessionId: env.sessionId)

    // when
    try env.usage.recordUsage(row)
    try env.usage.recordUsage(row)

    // then
    #expect(try Self.rowCount(env.queue) == 1)
    let (tokens, cost) = try env.usage.todayTokensAndCost(now: Self.fixedNow)
    #expect(tokens == 15)
    #expect(abs(cost - 0.002) < 1e-9)
  }

  @Test func twoDifferentCallsForOneRunBothStoreAndBothDebitTheDay() throws {
    // given — a run's tool loop legitimately spends once per round
    let env = try Self.fixture()

    // when
    try env.usage.recordUsage(
      Self.usage(callID: "call-1", runId: env.runId, sessionId: env.sessionId)
    )
    try env.usage.recordUsage(
      Self.usage(callID: "call-2", runId: env.runId, sessionId: env.sessionId)
    )

    // then — idempotency is per call, never per run
    #expect(try Self.rowCount(env.queue) == 2)
    let (tokens, cost) = try env.usage.todayTokensAndCost(now: Self.fixedNow)
    #expect(tokens == 30)
    #expect(abs(cost - 0.004) < 1e-9)
  }

  @Test func aRunlessScheduleParseIsIdempotentOnItsOwnCall() throws {
    // given — command spend carries no run, so the run can not be what distinguishes its rows
    let env = try Self.fixture()
    let row = Self.usage(callID: "call-parse", runId: nil, sessionId: env.sessionId)

    // when
    try env.usage.recordUsage(row)
    try env.usage.recordUsage(row)

    // then
    #expect(try Self.rowCount(env.queue) == 1)
    #expect(try env.usage.todayTokensAndCost(now: Self.fixedNow).tokens == 15)
  }

  @Test func twoRunlessParsesWithDistinctCallsBothStore() throws {
    // given — the run id is NULL on both, so only the call identity separates them
    let env = try Self.fixture()

    // when
    try env.usage.recordUsage(Self.usage(callID: "call-a", runId: nil, sessionId: env.sessionId))
    try env.usage.recordUsage(Self.usage(callID: "call-b", runId: nil, sessionId: env.sessionId))

    // then
    #expect(try Self.rowCount(env.queue) == 2)
    #expect(try env.usage.todayTokensAndCost(now: Self.fixedNow).tokens == 30)
  }

  @Test func aRecordNamingAnUnknownRunSurfacesTheFailureRatherThanBeingSilenced() throws {
    // given — the conflict clause silences a repeated call identity and nothing else; a corrupt
    // row must not reach the caller wearing the same "already recorded, nothing to do" face
    let env = try Self.fixture()

    // when / then
    #expect(throws: StoreError.self) {
      try env.usage.recordUsage(
        Self.usage(callID: "call-orphan", runId: 9999, sessionId: env.sessionId)
      )
    }
    #expect(try Self.rowCount(env.queue) == 0)
  }

  @Test func aRecordNamingAnUnknownSessionSurfacesTheFailureRatherThanBeingSilenced() throws {
    // given
    let env = try Self.fixture()

    // when / then
    #expect(throws: StoreError.self) {
      try env.usage.recordUsage(
        Self.usage(callID: "call-orphan", runId: env.runId, sessionId: 9999)
      )
    }
    #expect(try Self.rowCount(env.queue) == 0)
  }
}

// MARK: - Fixture

private extension UsageStoreTests {
  struct Fixture {
    let queue: DatabaseQueue
    let usage: UsageStoreGRDB
    let sessionId: Int64
    let runId: Int64
  }

  static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

  static func fixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 42),
        chatId: 42,
        userId: 42,
        text: "seed",
        isEdited: false,
        ts: fixedNow
      )
    )
    return Fixture(
      queue: queue,
      usage: UsageStoreGRDB(writer: queue),
      sessionId: try #require(claim.sessionId),
      runId: try #require(claim.runId)
    )
  }

  static func usage(
    callID: String,
    runId: Int64?,
    sessionId: Int64,
    promptTokens: Int = 10,
    isEstimated: Bool = false
  ) -> ProviderUsage {
    ProviderUsage(
      providerCallID: ProviderCallID(rawValue: callID),
      runId: runId,
      sessionId: sessionId,
      model: "m",
      promptTokens: promptTokens,
      completionTokens: 5,
      costUSD: 0.002,
      costSource: .providerReturned,
      isEstimated: isEstimated,
      ts: fixedNow
    )
  }

  static func rowCount(_ queue: DatabaseQueue) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage") ?? -1
    }
  }
}
