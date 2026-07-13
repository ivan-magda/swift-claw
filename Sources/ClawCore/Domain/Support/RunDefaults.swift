/// The LLM run-bound defaults shared by the config layer (`AppConfig.EnvDefaults`) and the domain
/// failsafe (`RunBudget.default`), so the two can never drift apart on the same number.
enum RunDefaults {
  static let maxOutputTokens = 4096
  static let retryBudget = 3
  static let proactivePerDayUSD = 2.00
}
