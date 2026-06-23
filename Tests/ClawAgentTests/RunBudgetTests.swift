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
      expectedCap: "per-day token"
    ),
    DenyCase(
      todayTokens: 0,
      todayUSD: 10.0,
      estimatedTotalTokens: 100,
      expectedCap: "per-day spend"
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
    #expect(decision == .deny(cap: "per-run spend"))
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
