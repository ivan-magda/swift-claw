import ClawCore
import Testing

@testable import ClawGateway

@Suite struct HealthRowsBuilderTests {
  private func inputs(
    allowlist: AllowlistHealth = AllowlistHealth(seeded: 1, configured: 1),
    freeBytes: Int = 1000,
    todayUSD: Double = 0.5,
    perDayUSD: Double = 10
  ) -> HealthRowsBuilder.Inputs {
    HealthRowsBuilder.Inputs(
      allowlist: allowlist,
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

  private func allowlistRow(seeded: Int?, configured: Int) -> DoctorReport.Check? {
    HealthRowsBuilder
      .checks(inputs(allowlist: AllowlistHealth(seeded: seeded, configured: configured)))
      .first { $0.key == "allowlist.owners" }
  }

  @Test func allowlistFailsWhenNoOwnersConfiguredOrSeeded() {
    // given — genuinely ownerless: config names nobody and nothing was ever seeded
    // when
    let row = allowlistRow(seeded: 0, configured: 0)

    // then
    #expect(row?.ok == false)
    #expect(row?.value == "0")
  }

  @Test func allowlistPassesOnConfiguredOwnersBeforeFirstRunSeedsTheTable() {
    // given — a fresh install: CLAW_ALLOWLIST names the owner, `run` has not seeded the table yet
    // when
    let row = allowlistRow(seeded: 0, configured: 1)

    // then — config alone keeps the check healthy and the value explains the pending seed
    #expect(row?.ok == true)
    #expect(row?.value == "0 seeded, 1 configured (seeded at daemon start)")
  }

  @Test func allowlistReportsTheSeededCountOnceTheTableHasOwners() {
    // given — pairing grew the table beyond config; the table is the enforced boundary
    // when
    let row = allowlistRow(seeded: 2, configured: 1)

    // then
    #expect(row?.ok == true)
    #expect(row?.value == "2")
  }

  @Test func allowlistKeepsPassingWhenConfigIsTrimmedBelowTheSeededTable() {
    // given — seeding is additive, so owners persist after their ID leaves CLAW_ALLOWLIST
    // when
    let row = allowlistRow(seeded: 1, configured: 0)

    // then
    #expect(row?.ok == true)
    #expect(row?.value == "1")
  }

  @Test func allowlistFailsWhenTheStoreReadFailsEvenWithConfiguredOwners() {
    // given — the allowlist read threw; the boundary fails closed, locking every owner out
    // when
    let row = allowlistRow(seeded: nil, configured: 3)

    // then — configured owners must not mask a broken access boundary
    #expect(row?.ok == false)
    #expect(row?.value == "unreadable (db read failed)")
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
