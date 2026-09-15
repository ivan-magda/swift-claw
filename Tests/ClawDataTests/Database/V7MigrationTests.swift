import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct V7MigrationTests {
  private func makeSession(_ queue: DatabaseQueue) throws -> Int64 {
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: "tg:dm:7",
        chatID: 7,
        userID: 7,
        text: "schedule something",
        isEdited: false,
        ts: Date()
      )
    )
    return claim.sessionID ?? 0
  }

  private func runlessUsage(sessionID: Int64) -> ProviderUsage {
    ProviderUsage(
      providerCallID: ProviderCallID(rawValue: "call-1"),
      runID: nil,
      sessionID: sessionID,
      model: "m",
      promptTokens: 10,
      completionTokens: 4,
      costUSD: 0.002,
      costSource: .heuristic,
      isEstimated: false,
      ts: Date()
    )
  }

  @Test
  func vSevenAcceptsUsageRowsWithoutARunAndDayTotalsIncludeThem() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessionID = try makeSession(queue)
    let usage = UsageStoreGRDB(writer: queue)

    // when — a command-scoped row with no owning run
    try usage.recordUsage(runlessUsage(sessionID: sessionID))

    // then — the row lands with a NULL run_id and the plain day window counts it
    let totals = try usage.todayTokensAndCost(now: Date())
    #expect(totals.tokens == 14)
    #expect(totals.costUSD == 0.002)
  }

  @Test
  func originFilteredTotalsExcludeRunlessRows() throws {
    // given — the proactive pool JOINs runs, so command spend must never debit it
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessionID = try makeSession(queue)
    let usage = UsageStoreGRDB(writer: queue)
    try usage.recordUsage(runlessUsage(sessionID: sessionID))

    // when
    let proactive = try usage.todayTokensAndCost(origins: [.scheduled, .heartbeat], now: Date())

    // then
    #expect(proactive.tokens == 0)
    #expect(proactive.costUSD == 0)
  }
}
