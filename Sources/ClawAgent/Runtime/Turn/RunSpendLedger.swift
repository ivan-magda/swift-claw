import ClawCore

/// What this run has spent so far and the per-run caps checked against it. A resumed run seeds the
/// counters from the usage it recorded before suspending, so a suspension never resets a cap.
struct RunSpendLedger {
  /// The round-trips this segment may make. The wall clock is fresh for every segment, so only the
  /// rounds already consumed carry over; a segment always gets at least one.
  let roundIndices: ClosedRange<Int>
  private(set) var recordedTokens: Int
  private var recordedUSD: Double
  private var proposedToolCalls: Int

  private let budget: RunBudget
  private let origin: RunOrigin
  private let spend: SpendSnapshot

  init(budget: RunBudget, origin: RunOrigin, spend: SpendSnapshot) {
    roundIndices = 1...max(1, budget.maxTurns - (spend.carryOver?.rounds ?? 0))
    recordedTokens = spend.carryOver?.tokens ?? 0
    recordedUSD = spend.carryOver?.costUSD ?? 0
    proposedToolCalls = spend.carryOver?.toolCalls ?? 0

    self.budget = budget
    self.origin = origin
    self.spend = spend
  }

  /// The first cap the next call would breach, or `.allow`. The order is the contract: the input
  /// cap, this run's spend on a metered route, then the route's daily gate.
  func preflight(
    _ estimate: ProviderUsageAccountant.PreflightEstimate,
    on route: ActiveRoute
  ) -> BudgetDecision {
    if estimate.inputTokens > budget.maxInputTokens {
      return .deny(cap: BudgetGate.perRunInputTokenCap)
    }

    if route.binding.costPolicy == .metered, recordedUSD + estimate.costUSD > budget.perRunUSD {
      return .deny(cap: BudgetGate.perRunSpendCap)
    }

    return route.gate.preflight(
      todayTokens: spend.todayTokens + recordedTokens,
      todayUSD: spend.todayUSD + recordedUSD,
      estimatedTotalTokens: estimate.totalTokens,
      estimatedCostUSD: estimate.costUSD,
      origin: origin,
      proactiveTodayUSD: spend.proactiveTodayUSD + recordedUSD
    )
  }

  /// Debits one recorded usage row against the run's totals.
  mutating func record(_ usage: ProviderUsage) {
    recordedTokens += usage.promptTokens + usage.completionTokens
    recordedUSD += usage.costUSD
  }

  /// Counts one proposed tool call; false once the run is past its tool-call cap.
  mutating func admitToolCall() -> Bool {
    proposedToolCalls += 1
    return proposedToolCalls <= budget.maxToolCalls
  }
}
