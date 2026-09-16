import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawData

@Suite
struct RunsHealthTests {
  private struct Fixture {
    let sessions: SessionMessageStoreGRDB
    let store: RunStoreGRDB
    let usage: UsageStoreGRDB
    let sessionID: Int64
  }

  private func makeFixture() throws -> Fixture {
    let queue = try TestDatabase.make()
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let sessionID = try sessions.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatID: 1),
      now: Date()
    )
    return Fixture(
      sessions: sessions,
      store: RunStoreGRDB(writer: queue),
      usage: UsageStoreGRDB(writer: queue),
      sessionID: sessionID
    )
  }

  private func seedPendingRun(
    sessions: SessionMessageStoreGRDB,
    updateID: Int64,
    chatID: Int64 = 1,
    ts: Date
  ) throws -> Int64 {
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: updateID,
        sessionKey: SessionKey.telegramDM(chatID: chatID),
        chatID: chatID,
        userID: chatID,
        text: "seed",
        isEdited: false,
        ts: ts
      )
    )
    return try #require(claim.runID)
  }

  private func seedUsage(
    _ usage: UsageStoreGRDB,
    runID: Int64,
    sessionID: Int64,
    source: CostSource,
    now: Date
  ) throws {
    try usage.recordUsage(
      makeProviderUsage(
        runID: runID,
        sessionID: sessionID,
        callID: "call-run-\(runID)",
        costSource: source,
        ts: now
      )
    )
  }

  private func commitDone(fixture: Fixture, updateID: Int64, chatID: Int64, now: Date) throws {
    let runID = try seedPendingRun(
      sessions: fixture.sessions,
      updateID: updateID,
      chatID: chatID,
      ts: now
    )
    _ = try #require(try fixture.store.pickUp(runID: runID, now: now))
    let usage = makeProviderUsage(
      runID: runID,
      sessionID: fixture.sessionID,
      callID: "call-run-\(runID)",
      costSource: .providerReturned,
      ts: now
    )
    _ = try fixture.store.commitAssistantTurn(
      AssistantTurn(
        runID: runID,
        sessionID: fixture.sessionID,
        chatID: chatID,
        content: "hi",
        usage: usage,
        chunks: []
      ),
      now: now.addingTimeInterval(1)
    )
  }

  @Test
  func reportsInFlightAndTrailingFailures() throws {
    // given — seed: 1 DONE, 2 FAILED, 1 PENDING (insertion order = ascending id)
    let fix = try makeFixture()
    let store = fix.store
    let base = Date(timeIntervalSinceReferenceDate: 0)

    try commitDone(fixture: fix, updateID: 1, chatID: 1, now: base)

    let failed1 = try seedPendingRun(
      sessions: fix.sessions,
      updateID: 2,
      ts: base.addingTimeInterval(2)
    )
    _ = try #require(try store.pickUp(runID: failed1, now: base.addingTimeInterval(2)))
    try store.failRun(runID: failed1, cause: .providerFailure, now: base.addingTimeInterval(3))

    let failed2 = try seedPendingRun(
      sessions: fix.sessions,
      updateID: 3,
      ts: base.addingTimeInterval(4)
    )
    _ = try #require(try store.pickUp(runID: failed2, now: base.addingTimeInterval(4)))
    try store.failRun(runID: failed2, cause: .providerFailure, now: base.addingTimeInterval(5))

    _ = try seedPendingRun(sessions: fix.sessions, updateID: 4, ts: base.addingTimeInterval(6))

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

  @Test
  func consecutiveFailuresCountsLeadingFailedStreak() throws {
    // given — seed: 1 DONE then 3 FAILED (no newer run)
    let fix = try makeFixture()
    let store = fix.store
    let base = Date(timeIntervalSinceReferenceDate: 0)

    try commitDone(fixture: fix, updateID: 1, chatID: 1, now: base)

    for (index, offset) in stride(from: 2.0, through: 6.0, by: 2.0).enumerated() {
      let runID = try seedPendingRun(
        sessions: fix.sessions,
        updateID: Int64(index + 2),
        ts: base.addingTimeInterval(offset)
      )
      _ = try #require(try store.pickUp(runID: runID, now: base.addingTimeInterval(offset)))
      try store.failRun(
        runID: runID,
        cause: .providerFailure,
        now: base.addingTimeInterval(offset + 1)
      )
    }

    // when
    let health = try store.runsHealth(now: base.addingTimeInterval(10))

    // then — 3 FAILED at the head of the table; DONE breaks the streak further down
    #expect(health.consecutiveFailures == 3)
    #expect(health.inFlight == 0)
  }

  @Test
  func streakBreaksAtFirstNonFailedRun() throws {
    // given — insertion order: FAILED, FAILED, DONE, FAILED
    // newest-first: FAILED(4), DONE(3), FAILED(2), FAILED(1) → streak = 1
    let fix = try makeFixture()
    let store = fix.store
    let base = Date(timeIntervalSinceReferenceDate: 0)

    let run1 = try seedPendingRun(sessions: fix.sessions, updateID: 1, ts: base)
    _ = try #require(try store.pickUp(runID: run1, now: base))
    try store.failRun(runID: run1, cause: .providerFailure, now: base.addingTimeInterval(1))

    let run2 = try seedPendingRun(
      sessions: fix.sessions,
      updateID: 2,
      ts: base.addingTimeInterval(2)
    )
    _ = try #require(try store.pickUp(runID: run2, now: base.addingTimeInterval(2)))
    try store.failRun(runID: run2, cause: .providerFailure, now: base.addingTimeInterval(3))

    try commitDone(fixture: fix, updateID: 3, chatID: 1, now: base.addingTimeInterval(4))

    let run4 = try seedPendingRun(
      sessions: fix.sessions,
      updateID: 4,
      ts: base.addingTimeInterval(6)
    )
    _ = try #require(try store.pickUp(runID: run4, now: base.addingTimeInterval(6)))
    try store.failRun(runID: run4, cause: .providerFailure, now: base.addingTimeInterval(7))

    // when
    let health = try store.runsHealth(now: base.addingTimeInterval(10))

    // then — only the most-recent FAILED counts; DONE at id 3 breaks the streak
    #expect(health.consecutiveFailures == 1)
  }

  @Test
  func emptyTableReportsAllZeroAndNil() throws {
    // given — fresh DB, no runs inserted
    let queue = try TestDatabase.make()
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

  @Test
  func costSourceMixCountsTodayRowsBySource() throws {
    // given
    let fix = try makeFixture()
    let usage = fix.usage
    let sessionID = fix.sessionID
    let now = Date()

    let runID1 = try seedPendingRun(sessions: fix.sessions, updateID: 1, ts: now)
    let runID2 = try seedPendingRun(sessions: fix.sessions, updateID: 2, ts: now)
    try seedUsage(usage, runID: runID1, sessionID: sessionID, source: .providerReturned, now: now)
    try seedUsage(usage, runID: runID2, sessionID: sessionID, source: .heuristic, now: now)

    // when
    let mix = try usage.costSourceMix(now: now)

    // then
    #expect(mix[.providerReturned] == 1)
    #expect(mix[.heuristic] == 1)
    #expect(mix[.priceFile] == nil)
  }
}
