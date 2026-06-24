import ClawCore
import Foundation
import Testing

@testable import ClawData

@Suite struct RunsHealthTests {
  private struct Fixture {
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
      store: RunStoreGRDB(writer: queue),
      usage: UsageStoreGRDB(writer: queue),
      sessionId: sessionId
    )
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
    store: RunStoreGRDB,
    sessionId: Int64,
    chatId: Int64,
    now: Date
  ) throws {
    let runId = try store.createRun(sessionId: sessionId, now: now)
    let usage = ProviderUsage(
      runId: runId,
      sessionId: sessionId,
      model: "m",
      promptTokens: 10,
      completionTokens: 5,
      costUSD: 0.001,
      costSource: .providerReturned,
      isEstimated: false,
      ts: now
    )
    try store.commitAssistantTurn(
      AssistantTurn(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        content: "hi",
        usage: usage,
        chunks: []
      ),
      now: now.addingTimeInterval(1)
    )
  }

  @Test func reportsInFlightAndTrailingFailures() throws {
    // given — seed: 1 DONE, 2 FAILED, 1 RUNNING (insertion order = ascending id)
    let fix = try makeFixture()
    let store = fix.store
    let sid = fix.sessionId
    let base = Date(timeIntervalSinceReferenceDate: 0)

    try commitDone(store: store, sessionId: sid, chatId: 2, now: base)

    let failed1 = try store.createRun(sessionId: sid, now: base.addingTimeInterval(2))
    try store.failRun(runId: failed1, now: base.addingTimeInterval(3))

    let failed2 = try store.createRun(sessionId: sid, now: base.addingTimeInterval(4))
    try store.failRun(runId: failed2, now: base.addingTimeInterval(5))

    // RUNNING — left open (simulates in-flight); created at base+6
    _ = try store.createRun(sessionId: sid, now: base.addingTimeInterval(6))

    let now = base.addingTimeInterval(10)

    // when
    let health = try store.runsHealth(now: now)

    // then
    #expect(health.inFlight == 1)
    // RUNNING run created at base+6, now = base+10 → age = 4 s
    let age = try #require(health.oldestRunAgeSeconds)
    #expect(age == 4)
    // DONE updated at base+1; last FAILED updated at base+5
    let successAt = try #require(health.lastSuccessAt)
    #expect(successAt == base.addingTimeInterval(1))
    let failedAt = try #require(health.lastFailedAt)
    #expect(failedAt == base.addingTimeInterval(5))
    // Most-recent run (highest id) is RUNNING — streak is 0
    #expect(health.consecutiveFailures == 0)
  }

  @Test func consecutiveFailuresCountsLeadingFailedStreak() throws {
    // given — seed: 1 DONE then 3 FAILED (no newer run)
    let fix = try makeFixture()
    let store = fix.store
    let sid = fix.sessionId
    let base = Date(timeIntervalSinceReferenceDate: 0)

    try commitDone(store: store, sessionId: sid, chatId: 3, now: base)

    for offset in stride(from: 2.0, through: 6.0, by: 2.0) {
      let runId = try store.createRun(sessionId: sid, now: base.addingTimeInterval(offset))
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
    let sid = fix.sessionId
    let base = Date(timeIntervalSinceReferenceDate: 0)

    let run1 = try store.createRun(sessionId: sid, now: base)
    try store.failRun(runId: run1, now: base.addingTimeInterval(1))

    let run2 = try store.createRun(sessionId: sid, now: base.addingTimeInterval(2))
    try store.failRun(runId: run2, now: base.addingTimeInterval(3))

    try commitDone(store: store, sessionId: sid, chatId: 4, now: base.addingTimeInterval(4))

    let run4 = try store.createRun(sessionId: sid, now: base.addingTimeInterval(6))
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
    let store = fix.store
    let usage = fix.usage
    let sessionId = fix.sessionId
    let now = Date()

    let runId1 = try store.createRun(sessionId: sessionId, now: now)
    let runId2 = try store.createRun(sessionId: sessionId, now: now)
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
