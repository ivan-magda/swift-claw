import ClawCore
import Testing

@testable import ClawGateway

@Suite struct HealthRowsBuilderTests {
  private func inputs(
    owners: Int = 1,
    freeBytes: Int = 1000,
    todayUSD: Double = 0.5,
    perDayUSD: Double = 10
  ) -> HealthRowsBuilder.Inputs {
    HealthRowsBuilder.Inputs(
      allowlistOwners: owners,
      lastOffset: 42,
      runsHealth: RunsHealth(
        inFlight: 0,
        oldestRunAgeSeconds: nil,
        lastFailedAt: nil,
        lastSuccessAt: nil,
        consecutiveFailures: 0
      ),
      retryBudget: 3,
      streamingEnabled: true,
      todayTokens: 100,
      todayUSD: todayUSD,
      costMix: [:],
      perDayUSD: perDayUSD,
      perRunUSD: 0.5,
      walBytes: 12,
      freeBytes: freeBytes
    )
  }

  @Test func tagsEachSubsystemWithItsGroup() {
    // given / when
    let checks = HealthRowsBuilder.checks(inputs())
    let byKey = Dictionary(checks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

    // then
    #expect(byKey["allowlist.owners"]?.group == .database)
    #expect(byKey["llm.retry_budget"]?.group == .llmRuns)
    #expect(byKey["spend.per_run_cap_usd"]?.group == .spend)
    #expect(byKey["db.wal_size"]?.group == .storage)
  }

  @Test func allowlistWithNoOwnersFails() {
    // when
    let checks = HealthRowsBuilder.checks(inputs(owners: 0))

    // then
    #expect(checks.first { $0.key == "allowlist.owners" }?.ok == false)
  }

  @Test func zeroFreeDiskFails() {
    // when
    let checks = HealthRowsBuilder.checks(inputs(freeBytes: 0))

    // then
    #expect(checks.first { $0.key == "db.free_disk" }?.ok == false)
  }

  @Test func remainingSpendClampsAtZeroWhenOverBudget() {
    // when
    let checks = HealthRowsBuilder.checks(inputs(todayUSD: 20, perDayUSD: 10))

    // then
    #expect(checks.first { $0.key == "spend.remaining_day_usd" }?.value == USD.display(0))
  }

  @Test func dynamicSignalsAreHeadlinesStaticConfigIsNot() {
    // given / when
    let checks = HealthRowsBuilder.checks(inputs())
    let byKey = Dictionary(checks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

    // then — figures the owner checks /status for ride the group line…
    #expect(byKey["llm.consecutive_failures"]?.isHeadline == true)
    #expect(byKey["runs.in_flight"]?.isHeadline == true)
    #expect(byKey["spend.today_usd"]?.isHeadline == true)
    #expect(byKey["spend.remaining_day_usd"]?.isHeadline == true)
    // …while static config echoes stay collapsed
    #expect(byKey["llm.retry_budget"]?.isHeadline == false)
    #expect(byKey["llm.streaming"]?.isHeadline == false)
    #expect(byKey["spend.per_run_cap_usd"]?.isHeadline == false)
  }

  @Test func emptyCostMixRendersAsNone() {
    // when
    let checks = HealthRowsBuilder.checks(inputs())

    // then
    #expect(checks.first { $0.key == "spend.cost_source_mix" }?.value == "none")
  }
}
