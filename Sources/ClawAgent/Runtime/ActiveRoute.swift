import ClawCore

/// One route bound to the per-turn collaborators derived from it. The accountant and the budget
/// gate are built from the route's own policies rather than the runtime's, which is what lets a
/// metered fallback be charged and capped as metered after the primary was an included plan.
struct ActiveRoute {
  let binding: LLMRouteBinding
  let position: RoutePosition
  let accountant: ProviderUsageAccountant
  let gate: BudgetGate

  init(
    selection: RouteSelection,
    budget: RunBudget,
    costResolver: CostResolver,
    usageResolver: UsageResolver
  ) {
    let binding = selection.binding
    self.binding = binding
    self.position = selection.position
    accountant = ProviderUsageAccountant(
      configuredReference: binding.configuredReference,
      costPolicy: binding.costPolicy,
      reservationPolicy: binding.reservationPolicy,
      costResolver: costResolver,
      usageResolver: usageResolver,
      outputCap: budget.maxOutputTokens
    )
    gate = BudgetGate(budget: budget, costPolicy: binding.costPolicy)
  }
}
