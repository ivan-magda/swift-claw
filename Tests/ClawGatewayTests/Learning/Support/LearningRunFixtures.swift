import ClawCore

enum LearningRunFixtures {
  static func routeBinding(provider: any LLMProvider, reference: String) -> LLMRouteBinding {
    LLMRouteBinding(
      provider: provider,
      wireModel: reference,
      configuredReference: reference,
      costPolicy: .metered,
      reservationPolicy: .textOnly
    )
  }

  static func budget(proactivePerDayUSD: Double) -> RunBudget {
    let base = RunBudget.default
    return RunBudget(
      maxInputTokens: base.maxInputTokens,
      maxOutputTokens: base.maxOutputTokens,
      wallClockDeadlineSeconds: base.wallClockDeadlineSeconds,
      retryBudget: base.retryBudget,
      perRunUSD: base.perRunUSD,
      perDayUSD: base.perDayUSD,
      proactivePerDayUSD: proactivePerDayUSD,
      referenceUSDPerToken: base.referenceUSDPerToken
    )
  }
}
