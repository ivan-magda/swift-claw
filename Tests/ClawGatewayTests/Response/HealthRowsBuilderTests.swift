import ClawCore
import Testing

@testable import ClawGateway

@Suite struct HealthRowsBuilderTests {
  private func inputs(
    allowlist: AllowlistHealth = AllowlistHealth(seeded: 1, configured: 1),
    freeBytes: Int = 1000,
    todayUSD: Double = 0.5,
    perDayUSD: Double = 10,
    latestContext: LatestPromptUsage? = LatestPromptUsage(
      promptTokens: 13155,
      runId: 136,
      isEstimated: false
    ),
    routeHealth: LLMRouteHealth = LLMRouteHealth(
      primaryReference: "gpt-4o",
      fallbackReference: nil,
      cooldown: .clear
    )
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
      routeHealth: routeHealth,
      retryBudget: 3,
      streamingEnabled: true,
      todayTokens: 100,
      todayUSD: todayUSD,
      costMix: [:],
      perDayUSD: perDayUSD,
      perRunUSD: 0.5,
      walBytes: 12,
      freeBytes: freeBytes,
      latestContext: latestContext
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
    #expect(byKey["llm.active_route"]?.isHeadline == true)
    // …while static config echoes stay collapsed
    #expect(byKey["llm.retry_budget"]?.isHeadline == false)
    #expect(byKey["llm.streaming"]?.isHeadline == false)
    #expect(byKey["spend.per_run_cap_usd"]?.isHeadline == false)
    #expect(byKey["llm.fallback_configured"]?.isHeadline == false)
    // …and a cooldown window nobody is waiting out is not a signal
    #expect(byKey["llm.primary_cooldown_s"]?.isHeadline == false)
  }

  private func contextRow(latestContext: LatestPromptUsage?) -> DoctorReport.Check? {
    HealthRowsBuilder
      .checks(inputs(latestContext: latestContext))
      .first { $0.key == "context.last_prompt_tokens" }
  }

  @Test func contextRowReportsTheLastPromptSizeAnchoredToItsRun() {
    // when
    let row = contextRow(
      latestContext: LatestPromptUsage(promptTokens: 13155, runId: 136, isEstimated: false)
    )

    // then — an informational headline in its own group, never a failing check
    #expect(row?.value == "13155 (run 136)")
    #expect(row?.group == .context)
    #expect(row?.isHeadline == true)
    #expect(row?.ok == true)
  }

  @Test func contextRowOmitsTheRunAnchorForRunlessSpend() {
    // given — schedule parses record usage without a run
    // when
    let row = contextRow(
      latestContext: LatestPromptUsage(promptTokens: 210, runId: nil, isEstimated: false)
    )

    // then
    #expect(row?.value == "210")
  }

  @Test func contextRowMarksAnEstimatedRowAsApproximate() {
    // given — the newest row came from a degraded call, so its prompt count is a guess
    // when
    let row = contextRow(
      latestContext: LatestPromptUsage(promptTokens: 52012, runId: 140, isEstimated: true)
    )

    // then
    #expect(row?.value == "~52012 (run 140)")
  }

  @Test func contextRowRendersNoneBeforeAnyProviderCall() {
    // when
    let row = contextRow(latestContext: nil)

    // then
    #expect(row?.value == "none")
    #expect(row?.ok == true)
  }

  @Test func emptyCostMixRendersAsNone() {
    // when
    let checks = HealthRowsBuilder.checks(inputs())

    // then
    #expect(checks.first { $0.key == "spend.cost_source_mix" }?.value == "none")
  }

  private func routeRows(_ health: LLMRouteHealth) -> [String: String] {
    let checks = HealthRowsBuilder.checks(inputs(routeHealth: health))
    return Dictionary(checks.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
  }

  @Test func aLoneRouteReportsItselfActiveAndNoFallback() {
    // when
    let rows = routeRows(
      LLMRouteHealth(primaryReference: "gpt-4o", fallbackReference: nil, cooldown: .clear)
    )

    // then
    #expect(rows["llm.active_route"] == "gpt-4o")
    #expect(rows["llm.fallback_configured"] == "no")
    #expect(rows["llm.primary_cooldown_s"] == "none")
  }

  @Test func aCoolingPrimaryNamesTheFallbackAndTheWindow() {
    // when
    let rows = routeRows(
      LLMRouteHealth(
        primaryReference: "openai-chatgpt/gpt-5.4",
        fallbackReference: "gpt-4o",
        cooldown: .cooling(remainingSeconds: 840)
      )
    )

    // then — the row names the route the next turn starts on, and the window it is waiting out
    #expect(rows["llm.active_route"] == "gpt-4o (primary openai-chatgpt/gpt-5.4 cooling)")
    #expect(rows["llm.fallback_configured"] == "yes (gpt-4o)")
    #expect(rows["llm.primary_cooldown_s"] == "840")
  }

  @Test func aReaderOutsideTheDaemonClaimsNoLiveRoute() {
    // given — the windows live in the daemon's memory; this reader is another process
    // when
    let rows = routeRows(
      LLMRouteHealth(
        primaryReference: "gpt-4o",
        fallbackReference: "gpt-4o-mini",
        cooldown: .unobservable
      )
    )

    // then — the configured routes are reported, the live one is not guessed at
    #expect(rows["llm.active_route"] == "gpt-4o (configured primary)")
    #expect(rows["llm.fallback_configured"] == "yes (gpt-4o-mini)")
    #expect(rows["llm.primary_cooldown_s"] == "unknown")
  }

  private func telegramSummary(_ health: LLMRouteHealth) -> String {
    var report = DoctorReport()
    report.add(contentsOf: HealthRowsBuilder.checks(inputs(routeHealth: health)))
    return report.renderTelegramSummary()
  }

  @Test func telegramNamesTheAnsweringRouteOnEveryHealthyTurn() {
    // given — a healthy pair, the primary answering
    // when
    let summary = telegramSummary(
      LLMRouteHealth(
        primaryReference: "openai-chatgpt/gpt-5.4",
        fallbackReference: "gpt-4o",
        cooldown: .clear
      )
    )

    // then — Telegram is the daemon's only interface, and its summary keeps headlines only, so the
    // answering route has to be one
    #expect(summary.contains("active_route openai-chatgpt/gpt-5.4"))
    // …while a window that does not exist spends no slot on saying so
    #expect(summary.contains("primary_cooldown_s") == false)
  }

  @Test func telegramCarriesTheWindowOnlyWhileThePrimaryIsCooling() {
    // when
    let summary = telegramSummary(
      LLMRouteHealth(
        primaryReference: "openai-chatgpt/gpt-5.4",
        fallbackReference: "gpt-4o",
        cooldown: .cooling(remainingSeconds: 840)
      )
    )

    // then — the owner sees which model is answering and how long the primary is out
    #expect(summary.contains("active_route gpt-4o (primary openai-chatgpt/gpt-5.4 cooling)"))
    #expect(summary.contains("primary_cooldown_s 840"))
  }

  @Test func fallbackConfigurationStaysOffTheTelegramSummary() {
    // given / when — configuration an owner set themselves, unchanged between turns
    let summary = telegramSummary(
      LLMRouteHealth(
        primaryReference: "gpt-4o",
        fallbackReference: "gpt-4o-mini",
        cooldown: .clear
      )
    )

    // then — `doctor --check-config` is where a config echo belongs; the group line stays for state
    #expect(summary.contains("fallback_configured") == false)
  }
}
