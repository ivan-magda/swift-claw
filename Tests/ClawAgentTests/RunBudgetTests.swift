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

  @Test("preflight denies when today plus the estimate would cross the token ceiling")
  func preflightDeniesWhenTodayPlusEstimateExceedsTokenCeiling() {
    // given
    let gate = BudgetGate(budget: .default)

    // when
    let decision = gate.preflight(todayTokens: 666_000, todayUSD: 0, estimatedTotalTokens: 5_000)

    // then
    #expect(decision == .deny(cap: "per-day token ceiling"))
  }

  @Test("preflight denies when the daily USD cap is already met")
  func preflightDeniesWhenDailyUSDAlreadyMet() {
    // given
    let gate = BudgetGate(budget: .default)

    // when
    let decision = gate.preflight(todayTokens: 0, todayUSD: 10.0, estimatedTotalTokens: 100)

    // then
    #expect(decision == .deny(cap: "per-day USD cap"))
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
}
