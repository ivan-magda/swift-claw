import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

/// Pins the seam that Task 20b threads: `TurnRunner` must compute the proactive-budget "today"
/// window from its injected `now`, not the real wall clock. The shared fixture (`makeEnv`, `Env`,
/// `latestRunState`, `okResponse`, `StubLLMProvider`) lives in the sibling `TurnRunnerTests.swift`.
@Suite struct TurnRunnerBudgetTests {
  /// 2020-01-01 12:00:00 UTC — a fixed instant far from any real "today", so the seeded spend only
  /// falls inside the proactive window when the read honors the injected clock.
  private static let fixed = Date(timeIntervalSince1970: 1_577_880_000)

  @Test func proactiveBudgetWindowReadsInjectedNowNotWallClock() async throws {
    // given — a scheduled run whose proactive pool already overspent (3.00 ≥ 2.00 cap) on `fixed`'s
    // UTC day, with the runner's clock pinned to that same instant
    let env = try makeEnv(
      agentOutcome: .respond(okResponse(content: "should never run")),
      now: { Self.fixed }
    )
    try await env.queue.write { db in
      try db.execute(
        sql: "UPDATE runs SET origin = 'scheduled' WHERE id = ?",
        arguments: [env.runId]
      )
    }
    try UsageStoreGRDB(writer: env.queue).recordUsage(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-proactive-seed"),
        runId: env.runId,
        sessionId: env.sessionId,
        model: "m",
        promptTokens: 10,
        completionTokens: 5,
        costUSD: 3.00,
        costSource: .heuristic,
        isEstimated: true,
        ts: Self.fixed
      )
    )

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then — preflight denied by the proactive cap: model never ran, run FAILED with the cap copy.
    // With the old real-clock read the seed sits in 2020, the window finds nothing, and the run
    // proceeds — so this assertion is what fails before the injected-now change lands.
    #expect(await env.provider.callCount == 0)
    #expect(try latestRunState(env.queue) == "FAILED")
    let pending = try env.outbox.pendingOutbound()
    #expect(pending.first?.payload == Degradation.budget(cap: BudgetGate.proactivePerDayCap))
  }
}
