import ClawCore
import Foundation
import Testing

@testable import ClawData

@Suite struct UsageStoreTests {
  @Test func todayTotalsSumTokensAndCostInTheUtcDay() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let sessionId = try sessions.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 42),
      now: Date()
    )
    let runId = try RunStoreGRDB(writer: queue).createRun(sessionId: sessionId, now: Date())
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
}
