import Testing

@testable import ClawCore

@Suite("RunBudget")
struct RunBudgetTests {
  @Test("defaults are mutually consistent: one run is far below the day ceiling")
  func defaultsAreMutuallyConsistent() {
    // given
    let budget = RunBudget.default

    // then
    #expect(budget.dayTokenCeiling == 666_666)
    #expect(budget.maxInputTokens + budget.maxOutputTokens < budget.dayTokenCeiling)
  }

  struct DenyCase: CustomTestStringConvertible, Sendable {
    let todayTokens: Int
    let todayUSD: Double
    let estimatedTotalTokens: Int
    let expectedCap: String

    var testDescription: String { "deny — \(expectedCap)" }
  }

  static let denyCases: [DenyCase] = [
    DenyCase(
      todayTokens: 666_000,
      todayUSD: 0,
      estimatedTotalTokens: 5_000,
      expectedCap: BudgetGate.perDayTokenCap
    ),
    DenyCase(
      todayTokens: 0,
      todayUSD: 10.0,
      estimatedTotalTokens: 100,
      expectedCap: BudgetGate.perDaySpendCap
    ),
  ]

  @Test("preflight denies when a cap is exceeded", arguments: denyCases)
  func preflightDeniesWhenCapExceeded(_ testCase: DenyCase) {
    // given
    let gate = BudgetGate(budget: .default)

    // when
    let decision = gate.preflight(
      todayTokens: testCase.todayTokens,
      todayUSD: testCase.todayUSD,
      estimatedTotalTokens: testCase.estimatedTotalTokens
    )

    // then
    #expect(decision == .deny(cap: testCase.expectedCap))
  }

  @Test("preflight denies when this run's estimated cost exceeds the per-run cap")
  func preflightDeniesWhenEstimatedRunCostExceedsPerRunCap() {
    // given
    let gate = BudgetGate(budget: .default)

    // when
    let decision = gate.preflight(
      todayTokens: 0,
      todayUSD: 0,
      estimatedTotalTokens: 5_000,
      estimatedCostUSD: 0.60
    )

    // then
    #expect(decision == .deny(cap: BudgetGate.perRunSpendCap))
  }

  @Test("preflight allows a fresh day")
  func preflightAllowsAFreshDay() {
    // given
    let gate = BudgetGate(budget: .default)

    // when
    let decision = gate.preflight(todayTokens: 0, todayUSD: 0, estimatedTotalTokens: 5_000)

    // then
    #expect(decision == .allow)
  }

  @Test("a proactive run is denied at the proactive cap while the global caps still pass")
  func proactivePreflightDeniesAtTheProactiveCap() {
    // given — default budget: proactive cap 2.00 nested inside the 10.00 global cap
    let gate = BudgetGate(budget: .default)

    // when — 2.00 of proactive spend today; the global pool is far from its cap
    let scheduled = gate.preflight(
      todayTokens: 0,
      todayUSD: 2.0,
      estimatedTotalTokens: 1_000,
      estimatedCostUSD: 0.01,
      origin: .scheduled,
      proactiveTodayUSD: 2.0
    )
    let heartbeat = gate.preflight(
      todayTokens: 0,
      todayUSD: 2.0,
      estimatedTotalTokens: 1_000,
      estimatedCostUSD: 0.01,
      origin: .heartbeat,
      proactiveTodayUSD: 2.0
    )
    let interactive = gate.preflight(
      todayTokens: 0,
      todayUSD: 2.0,
      estimatedTotalTokens: 1_000,
      estimatedCostUSD: 0.01
    )

    // then — both proactive origins deny on the nested cap; interactive is untouched (S3)
    #expect(scheduled == .deny(cap: BudgetGate.proactivePerDayCap))
    #expect(heartbeat == .deny(cap: BudgetGate.proactivePerDayCap))
    #expect(interactive == .allow)
  }

  @Test("a proactive run whose estimate would cross the proactive cap is denied")
  func proactivePreflightDeniesWhenTheEstimateWouldCrossTheCap() {
    // given
    let gate = BudgetGate(budget: .default)

    // when — 1.99 spent, 0.02 estimated: 2.01 > 2.00
    let decision = gate.preflight(
      todayTokens: 0,
      todayUSD: 1.99,
      estimatedTotalTokens: 1_000,
      estimatedCostUSD: 0.02,
      origin: .scheduled,
      proactiveTodayUSD: 1.99
    )

    // then
    #expect(decision == .deny(cap: BudgetGate.proactivePerDayCap))
  }

  @Test("global checks run first, unchanged order — the household kill-switch wins")
  func globalChecksRunBeforeTheProactiveCheck() {
    // given — the global per-day cap is met AND the proactive pool is over its cap
    let gate = BudgetGate(budget: .default)

    // when
    let decision = gate.preflight(
      todayTokens: 0,
      todayUSD: 10.0,
      estimatedTotalTokens: 100,
      origin: .scheduled,
      proactiveTodayUSD: 5.0
    )

    // then — the GLOBAL cap is named, proving check order
    #expect(decision == .deny(cap: BudgetGate.perDaySpendCap))
  }

  @Test("a proactive run under the proactive cap is allowed")
  func proactivePreflightAllowsUnderTheCap() {
    // given
    let gate = BudgetGate(budget: .default)

    // when
    let decision = gate.preflight(
      todayTokens: 0,
      todayUSD: 0.50,
      estimatedTotalTokens: 1_000,
      estimatedCostUSD: 0.01,
      origin: .heartbeat,
      proactiveTodayUSD: 0.50
    )

    // then
    #expect(decision == .allow)
  }

  @Test("the included-plan policy skips every USD cap but keeps the daily token ceiling")
  func includedPlanPreflightSkipsUSDButKeepsTokenCeiling() {
    // given — a subscription gate whose day already crossed both the per-day and per-run USD caps
    let gate = BudgetGate(budget: .default, costPolicy: .includedPlan)

    // when — the USD figures alone would deny under `metered`, but the estimate stays under the
    // token ceiling
    let underToken = gate.preflight(
      todayTokens: 0,
      todayUSD: RunBudget.default.perDayUSD * 3,
      estimatedTotalTokens: 5_000,
      estimatedCostUSD: RunBudget.default.perRunUSD * 3,
      origin: .heartbeat,
      proactiveTodayUSD: RunBudget.default.proactivePerDayUSD * 3
    )
    // then — no USD comparison can reject a subscription call
    #expect(underToken == .allow)

    // when — the same policy still meets the hard offline token failsafe
    let overToken = gate.preflight(
      todayTokens: RunBudget.default.dayTokenCeiling,
      todayUSD: 0,
      estimatedTotalTokens: 1
    )
    // then — the token ceiling remains a live gate under the subscription policy
    #expect(overToken == .deny(cap: BudgetGate.perDayTokenCap))
  }

  @Test("a metered call over the per-day USD cap is still rejected")
  func meteredPreflightStillRejectsOnUSDCap() {
    // given — the metered counterpart of the included-plan skip, so the skip is not vacuous
    let gate = BudgetGate(budget: .default, costPolicy: .metered)

    // when
    let decision = gate.preflight(
      todayTokens: 0,
      todayUSD: RunBudget.default.perDayUSD,
      estimatedTotalTokens: 5_000,
      estimatedCostUSD: 0.01
    )

    // then
    #expect(decision == .deny(cap: BudgetGate.perDaySpendCap))
  }
}
