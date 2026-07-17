import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V7MigrationTests {
  private func makeSession(_ queue: DatabaseQueue) throws -> Int64 {
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: "tg:dm:7",
        chatId: 7,
        userId: 7,
        text: "schedule something",
        isEdited: false,
        ts: Date()
      )
    )
    return claim.sessionId ?? 0
  }

  private func runlessUsage(sessionId: Int64) -> ProviderUsage {
    ProviderUsage(
      providerCallID: ProviderCallID(rawValue: "call-1"),
      runId: nil,
      sessionId: sessionId,
      model: "m",
      promptTokens: 10,
      completionTokens: 4,
      costUSD: 0.002,
      costSource: .heuristic,
      isEstimated: false,
      ts: Date()
    )
  }

  @Test func vSevenAcceptsUsageRowsWithoutARunAndDayTotalsIncludeThem() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessionId = try makeSession(queue)
    let usage = UsageStoreGRDB(writer: queue)

    // when — a command-scoped row with no owning run
    try usage.recordUsage(runlessUsage(sessionId: sessionId))

    // then — the row lands with a NULL run_id and the plain day window counts it
    let totals = try usage.todayTokensAndCost(now: Date())
    #expect(totals.tokens == 14)
    #expect(totals.costUSD == 0.002)
  }

  @Test func originFilteredTotalsExcludeRunlessRows() throws {
    // given — the proactive pool JOINs runs, so command spend must never debit it
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessionId = try makeSession(queue)
    let usage = UsageStoreGRDB(writer: queue)
    try usage.recordUsage(runlessUsage(sessionId: sessionId))

    // when
    let proactive = try usage.todayTokensAndCost(
      origins: [.scheduled, .heartbeat],
      now: Date()
    )

    // then
    #expect(proactive.tokens == 0)
    #expect(proactive.costUSD == 0)
  }
}
