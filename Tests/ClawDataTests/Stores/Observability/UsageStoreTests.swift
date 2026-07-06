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

    // when — one query, one UTC-day-boundary evaluation (preamble deviation 2)
    let proactive = try usage.todayTokensAndCost(origins: [.scheduled, .heartbeat], now: now)
    let everything = try usage.todayTokensAndCost(now: now)
    let none = try usage.todayTokensAndCost(origins: [], now: now)

    // then — only the joined-origin usage is summed; the global total is untouched
    #expect(proactive.tokens == 15)
    #expect(abs(proactive.costUSD - 1.25) < 1e-9)
    #expect(everything.tokens == 165)
    #expect(none.tokens == 0)
    #expect(none.costUSD == 0)
  }
}
