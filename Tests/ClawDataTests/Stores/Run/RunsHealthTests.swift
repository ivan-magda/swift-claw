import ClawCore
import Foundation
import Testing

@testable import ClawData

@Suite struct RunsHealthTests {
  private struct Fixture {
    let sessions: SessionMessageStoreGRDB
    let store: RunStoreGRDB
    let usage: UsageStoreGRDB
    let sessionId: Int64
  }

  private func makeFixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let sessionId = try sessions.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 1),
      now: Date()
    )
    return Fixture(
      sessions: sessions,
      store: RunStoreGRDB(writer: queue),
      usage: UsageStoreGRDB(writer: queue),
      sessionId: sessionId
    )
  }

  private func seedPendingRun(
    sessions: SessionMessageStoreGRDB,
    updateId: Int64,
    chatId: Int64 = 1,
    ts: Date
  ) throws -> Int64 {
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: updateId,
        sessionKey: SessionKey.telegramDM(chatId: chatId),
        chatId: chatId,
        userId: chatId,
        text: "seed",
        isEdited: false,
        ts: ts
      )
    )
    return try #require(claim.runId)
  }

  private func seedUsage(
    _ usage: UsageStoreGRDB,
    runId: Int64,
    sessionId: Int64,
    source: CostSource,
    now: Date
  ) throws {
    try usage.recordUsage(
      ProviderUsage(
        runId: runId,
        sessionId: sessionId,
        model: "m",
        promptTokens: 10,
        completionTokens: 5,
        costUSD: 0.001,
        costSource: source,
        isEstimated: false,
        ts: now
      )
    )
  }

  private func commitDone(
    fixture: Fixture,
    updateId: Int64,
    chatId: Int64,
    now: Date
  ) throws {
    let runId = try seedPendingRun(
      sessions: fixture.sessions,
      updateId: updateId,
      chatId: chatId,
      ts: now
    )
    _ = try #require(try fixture.store.pickUp(runId: runId, now: now))
    let usage = ProviderUsage(
      runId: runId,
      sessionId: fixture.sessionId,
      model: "m",
      promptTokens: 10,
      completionTokens: 5,
      costUSD: 0.001,
      costSource: .providerReturned,
      isEstimated: false,
      ts: now
    )
    _ = try fixture.store.commitAssistantTurn(
      AssistantTurn(
        runId: runId,
        sessionId: fixture.sessionId,
        chatId: chatId,
        content: "hi",
        usage: usage,
        chunks: []
      ),
      now: now.addingTimeInterval(1)
    )
  }

  @Test func reportsInFlightAndTrailingFailures() throws {
    // given — seed: 1 DONE, 2 FAILED, 1 PENDING (insertion order = ascending id)
    let fix = try makeFixture()
    let store = fix.store
    let base = Date(timeIntervalSinceReferenceDate: 0)

    try commitDone(
      fixture: fix,
      updateId: 1,
      chatId: 1,
      now: base
    )

    let failed1 = try seedPendingRun(
      sessions: fix.sessions,
      updateId: 2,
      ts: base.addingTimeInterval(2)
    )
    _ = try #require(try store.pickUp(runId: failed1, now: base.addingTimeInterval(2)))
    try store.failRun(runId: failed1, now: base.addingTimeInterval(3))

    let failed2 = try seedPendingRun(
      sessions: fix.sessions,
      updateId: 3,
      ts: base.addingTimeInterval(4)
    )
    _ = try #require(try store.pickUp(runId: failed2, now: base.addingTimeInterval(4)))
    try store.failRun(runId: failed2, now: base.addingTimeInterval(5))

    _ = try seedPendingRun(
      sessions: fix.sessions,
      updateId: 4,
      ts: base.addingTimeInterval(6)
    )

    let now = base.addingTimeInterval(10)

    // when
    let health = try store.runsHealth(now: now)

    // then
    #expect(health.inFlight == 1)
    // PENDING run created at base+6, now = base+10 → age = 4 s
    let age = try #require(health.oldestRunAgeSeconds)
    #expect(age == 4)
    // DONE updated at base+1; last FAILED updated at base+5
    let successAt = try #require(health.lastSuccessAt)
    #expect(successAt == base.addingTimeInterval(1))
    let failedAt = try #require(health.lastFailedAt)
    #expect(failedAt == base.addingTimeInterval(5))
    // Most-recent run (highest id) is PENDING — streak is 0
    #expect(health.consecutiveFailures == 0)
  }

  @Test func consecutiveFailuresCountsLeadingFailedStreak() throws {
    // given — seed: 1 DONE then 3 FAILED (no newer run)
    let fix = try makeFixture()
    let store = fix.store
    let base = Date(timeIntervalSinceReferenceDate: 0)

    try commitDone(
      fixture: fix,
      updateId: 1,
      chatId: 1,
      now: base
    )

    for (index, offset) in stride(from: 2.0, through: 6.0, by: 2.0).enumerated() {
      let runId = try seedPendingRun(
        sessions: fix.sessions,
        updateId: Int64(index + 2),
        ts: base.addingTimeInterval(offset)
      )
      _ = try #require(try store.pickUp(runId: runId, now: base.addingTimeInterval(offset)))
      try store.failRun(runId: runId, now: base.addingTimeInterval(offset + 1))
    }

    // when
    let health = try store.runsHealth(now: base.addingTimeInterval(10))

    // then — 3 FAILED at the head of the table; DONE breaks the streak further down
    #expect(health.consecutiveFailures == 3)
    #expect(health.inFlight == 0)
  }

  @Test func streakBreaksAtFirstNonFailedRun() throws {
    // given — insertion order: FAILED, FAILED, DONE, FAILED
    // newest-first: FAILED(4), DONE(3), FAILED(2), FAILED(1) → streak = 1
    let fix = try makeFixture()
    let store = fix.store
    let base = Date(timeIntervalSinceReferenceDate: 0)

    let run1 = try seedPendingRun(sessions: fix.sessions, updateId: 1, ts: base)
    _ = try #require(try store.pickUp(runId: run1, now: base))
    try store.failRun(runId: run1, now: base.addingTimeInterval(1))

    let run2 = try seedPendingRun(
      sessions: fix.sessions,
      updateId: 2,
      ts: base.addingTimeInterval(2)
    )
    _ = try #require(try store.pickUp(runId: run2, now: base.addingTimeInterval(2)))
    try store.failRun(runId: run2, now: base.addingTimeInterval(3))

    try commitDone(
      fixture: fix,
      updateId: 3,
      chatId: 1,
      now: base.addingTimeInterval(4)
    )

    let run4 = try seedPendingRun(
      sessions: fix.sessions,
      updateId: 4,
      ts: base.addingTimeInterval(6)
    )
    _ = try #require(try store.pickUp(runId: run4, now: base.addingTimeInterval(6)))
    try store.failRun(runId: run4, now: base.addingTimeInterval(7))

    // when
    let health = try store.runsHealth(now: base.addingTimeInterval(10))

    // then — only the most-recent FAILED counts; DONE at id 3 breaks the streak
    #expect(health.consecutiveFailures == 1)
  }

  @Test func emptyTableReportsAllZeroAndNil() throws {
    // given — fresh DB, no runs inserted
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let store = RunStoreGRDB(writer: queue)

    // when
    let health = try store.runsHealth(now: Date())

    // then — MIN/MAX over empty set must decode as nil, not throw
    #expect(health.inFlight == 0)
    #expect(health.oldestRunAgeSeconds == nil)
    #expect(health.lastFailedAt == nil)
    #expect(health.lastSuccessAt == nil)
    #expect(health.consecutiveFailures == 0)
  }

  @Test func costSourceMixCountsTodayRowsBySource() throws {
    // given
    let fix = try makeFixture()
    let usage = fix.usage
    let sessionId = fix.sessionId
    let now = Date()

    let runId1 = try seedPendingRun(sessions: fix.sessions, updateId: 1, ts: now)
    let runId2 = try seedPendingRun(sessions: fix.sessions, updateId: 2, ts: now)
    try seedUsage(usage, runId: runId1, sessionId: sessionId, source: .providerReturned, now: now)
    try seedUsage(usage, runId: runId2, sessionId: sessionId, source: .heuristic, now: now)

    // when
    let mix = try usage.costSourceMix(now: now)

    // then
    #expect(mix[.providerReturned] == 1)
    #expect(mix[.heuristic] == 1)
    #expect(mix[.priceFile] == nil)
  }
}
