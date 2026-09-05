import Foundation

// MARK: - Budget Parsing

extension AppConfig {
  /// The spend budget mirrors `RunBudget.default`, except the four USD/ceiling knobs are env
  /// overridable and `maxOutputTokens`/`retryBudget` mirror `llm` (the single source of truth for
  /// those). Any present override must parse to a positive value, else fail-closed.
  static func parseBudget(
    from env: [String: String],
    llm: LLMConfig,
    proactivePerDayUSD: Double
  ) throws -> RunBudget {
    let base = RunBudget.default
    return RunBudget(
      maxInputTokens: base.maxInputTokens,
      maxOutputTokens: llm.maxOutputTokens,
      wallClockDeadlineSeconds: base.wallClockDeadlineSeconds,
      retryBudget: llm.retryBudget,
      perRunUSD: try positiveBudgetDouble(env[EnvKey.perRunUSD], default: base.perRunUSD),
      perDayUSD: try positiveBudgetDouble(env[EnvKey.perDayUSD], default: base.perDayUSD),
      proactivePerDayUSD: proactivePerDayUSD,
      referenceUSDPerToken: try positiveBudgetDouble(
        env[EnvKey.referenceUSDPerToken],
        default: base.referenceUSDPerToken
      ),
      maxTurns: try positiveBudgetInt(env[EnvKey.maxTurns], default: base.maxTurns),
      maxToolCalls: try positiveBudgetInt(env[EnvKey.maxToolCalls], default: base.maxToolCalls),
      dayTokenCeilingOverride: try positiveBudgetIntOrNil(env[EnvKey.dayTokenCeiling])
    )
  }

  /// A positive `Double` override: `fallback` when absent/blank, else `invalidBudget` on a
  /// non-numeric or non-positive value.
  static func positiveBudgetDouble(
    _ raw: String?,
    default fallback: Double
  ) throws -> Double {
    try ConfigParse.positiveDouble(raw, default: fallback, onInvalid: ConfigError.invalidBudget)
  }
}

// MARK: - Budget Integer Values

private extension AppConfig {
  /// A positive `Int` override: `fallback` when absent/blank, else `invalidBudget` on a
  /// non-numeric or non-positive value.
  static func positiveBudgetInt(_ raw: String?, default fallback: Int) throws -> Int {
    try ConfigParse.boundedInt(
      raw,
      default: fallback,
      range: 1...Int.max,
      onInvalid: ConfigError.invalidBudget
    )
  }

  /// An optional positive `Int` ceiling override; `nil` when absent so the budget derives it.
  static func positiveBudgetIntOrNil(_ raw: String?) throws -> Int? {
    try ConfigParse.boundedIntOrNil(
      raw,
      range: 1...Int.max,
      onInvalid: ConfigError.invalidBudget
    )
  }
}
