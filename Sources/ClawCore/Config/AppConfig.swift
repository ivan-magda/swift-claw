import Foundation

public struct AppConfig: Sendable, Equatable {
  enum EnvKey {
    static let allowlist = "CLAW_ALLOWLIST"
    static let stateRoot = "CLAW_STATE_ROOT"
    static let pollTimeout = "CLAW_POLL_TIMEOUT"

    static let llmBaseURL = "CLAW_LLM_BASE_URL"
    static let llmModel = "CLAW_LLM_MODEL"
    static let llmMaxTokensField = "CLAW_LLM_MAX_TOKENS_FIELD"
    static let llmMaxTokens = "CLAW_LLM_MAX_TOKENS"
    static let llmStreaming = "CLAW_LLM_STREAMING"

    static let perRunUSD = "CLAW_PER_RUN_USD"
    static let perDayUSD = "CLAW_PER_DAY_USD"
    static let referenceUSDPerToken = "CLAW_REFERENCE_USD_PER_TOKEN"
    static let dayTokenCeiling = "CLAW_DAY_TOKEN_CEILING"

    static let maxTurns = "CLAW_MAX_TURNS"
    static let maxToolCalls = "CLAW_MAX_TOOL_CALLS"

    static let timezone = "CLAW_TIMEZONE"
    static let schedCatchUpMaxAgeMinutes = "CLAW_SCHED_CATCHUP_MAX_AGE_MINUTES"
    static let schedMinIntervalMinutes = "CLAW_SCHED_MIN_INTERVAL_MINUTES"
    static let proactivePerDayUSD = "CLAW_PROACTIVE_PER_DAY_USD"

    static let heartbeatEnabled = "CLAW_HEARTBEAT_ENABLED"
    static let heartbeatIntervalMinutes = "CLAW_HEARTBEAT_INTERVAL_MINUTES"
    static let heartbeatQuietHours = "CLAW_HEARTBEAT_QUIET_HOURS"
    static let heartbeatMaxPerDay = "CLAW_HEARTBEAT_MAX_PER_DAY"
  }

  private enum EnvDefaults {
    static let pollTimeoutSeconds = 30
    static let stateDirectoryName = ".swift-claw"
    static let maxTokensField = MaxTokensField.maxCompletionTokens
    static let maxOutputTokens = 4096
    static let retryBudget = 3
    static let requestTimeoutSeconds = 180

    static let schedCatchUpMaxAgeMinutes = 30
    static let schedMinIntervalMinutes = 5
    static let proactivePerDayUSD = 2.00

    static let heartbeatIntervalMinutes = 60
    static let heartbeatQuietHours = "22:00-09:00"
    static let heartbeatMaxPerDay = 8
  }

  private static let stateRootPermissions = 0o700

  public let allowlist: Set<Int64>
  public let stateRoot: URL
  public let pollTimeoutSeconds: Int
  public let llm: LLMConfig
  public let budget: RunBudget

  public let timezone: TimeZone
  public let schedCatchUpMaxAgeMinutes: Int
  public let schedMinIntervalMinutes: Int
  public let proactivePerDayUSD: Double

  public let heartbeatEnabled: Bool
  public let heartbeatIntervalMinutes: Int
  public let heartbeatQuietHours: QuietHours
  public let heartbeatMaxPerDay: Int

  public init(
    allowlist: Set<Int64>,
    stateRoot: URL,
    pollTimeoutSeconds: Int,
    llm: LLMConfig,
    budget: RunBudget,
    timezone: TimeZone,
    schedCatchUpMaxAgeMinutes: Int,
    schedMinIntervalMinutes: Int,
    proactivePerDayUSD: Double,
    heartbeatEnabled: Bool,
    heartbeatIntervalMinutes: Int,
    heartbeatQuietHours: QuietHours,
    heartbeatMaxPerDay: Int
  ) {
    self.allowlist = allowlist
    self.stateRoot = stateRoot
    self.pollTimeoutSeconds = pollTimeoutSeconds
    self.llm = llm
    self.budget = budget
    self.timezone = timezone
    self.schedCatchUpMaxAgeMinutes = schedCatchUpMaxAgeMinutes
    self.schedMinIntervalMinutes = schedMinIntervalMinutes
    self.proactivePerDayUSD = proactivePerDayUSD
    self.heartbeatEnabled = heartbeatEnabled
    self.heartbeatIntervalMinutes = heartbeatIntervalMinutes
    self.heartbeatQuietHours = heartbeatQuietHours
    self.heartbeatMaxPerDay = heartbeatMaxPerDay
  }

  /// Loads and validates non-secret config from the environment. Secrets (the bot token / LLM key)
  /// are loaded separately via `SecretStore` and injected at the composition root. An empty
  /// allowlist is allowed so onboarding can still boot.
  public static func load(environment env: [String: String]) throws -> AppConfig {
    let allowlist = try parseAllowlist(from: env[EnvKey.allowlist])
    let stateRoot = try createStateRootURL(for: env[EnvKey.stateRoot])
    let pollTimeoutSeconds =
      env[EnvKey.pollTimeout].flatMap(Int.init) ?? EnvDefaults.pollTimeoutSeconds
    let llm = try parseLLMConfig(from: env)
    let proactivePerDayUSD = try positiveBudgetDouble(
      env[EnvKey.proactivePerDayUSD],
      default: EnvDefaults.proactivePerDayUSD
    )
    let budget = try parseBudget(from: env, llm: llm, proactivePerDayUSD: proactivePerDayUSD)

    let timezone = try parseTimezone(from: env[EnvKey.timezone])
    let schedCatchUpMaxAgeMinutes = try boundedInt(
      env[EnvKey.schedCatchUpMaxAgeMinutes],
      key: EnvKey.schedCatchUpMaxAgeMinutes,
      default: EnvDefaults.schedCatchUpMaxAgeMinutes,
      minimum: 1
    )
    let schedMinIntervalMinutes = try boundedInt(
      env[EnvKey.schedMinIntervalMinutes],
      key: EnvKey.schedMinIntervalMinutes,
      default: EnvDefaults.schedMinIntervalMinutes,
      minimum: 1
    )
    let heartbeatEnabled = try boolValue(
      env[EnvKey.heartbeatEnabled],
      key: EnvKey.heartbeatEnabled,
      default: false
    )
    let heartbeatIntervalMinutes = try boundedInt(
      env[EnvKey.heartbeatIntervalMinutes],
      key: EnvKey.heartbeatIntervalMinutes,
      default: EnvDefaults.heartbeatIntervalMinutes,
      minimum: 15
    )
    let heartbeatQuietHours = try parseQuietHours(from: env[EnvKey.heartbeatQuietHours])
    let heartbeatMaxPerDay = try boundedInt(
      env[EnvKey.heartbeatMaxPerDay],
      key: EnvKey.heartbeatMaxPerDay,
      default: EnvDefaults.heartbeatMaxPerDay,
      minimum: 1
    )

    return AppConfig(
      allowlist: allowlist,
      stateRoot: stateRoot,
      pollTimeoutSeconds: pollTimeoutSeconds,
      llm: llm,
      budget: budget,
      timezone: timezone,
      schedCatchUpMaxAgeMinutes: schedCatchUpMaxAgeMinutes,
      schedMinIntervalMinutes: schedMinIntervalMinutes,
      proactivePerDayUSD: proactivePerDayUSD,
      heartbeatEnabled: heartbeatEnabled,
      heartbeatIntervalMinutes: heartbeatIntervalMinutes,
      heartbeatQuietHours: heartbeatQuietHours,
      heartbeatMaxPerDay: heartbeatMaxPerDay
    )
  }

  /// `apiKey` is optional — local servers need none.
  private static func parseLLMConfig(from env: [String: String]) throws -> LLMConfig {
    guard
      let baseURL = env[EnvKey.llmBaseURL]?.trimmingCharacters(in: .whitespaces),
      !baseURL.isEmpty
    else {
      throw ConfigError.missingLLMBaseURL
    }

    guard
      let model = env[EnvKey.llmModel]?.trimmingCharacters(in: .whitespaces),
      !model.isEmpty
    else {
      throw ConfigError.missingLLMModel
    }

    let rawField = env[EnvKey.llmMaxTokensField]?.trimmingCharacters(in: .whitespaces) ?? ""
    let maxTokensField: MaxTokensField
    if rawField.isEmpty {
      maxTokensField = EnvDefaults.maxTokensField
    } else if let parsedField = MaxTokensField(rawValue: rawField) {
      maxTokensField = parsedField
    } else {
      throw ConfigError.invalidMaxTokensField(rawField)
    }

    let rawMaxTokens = env[EnvKey.llmMaxTokens]?.trimmingCharacters(in: .whitespaces) ?? ""
    let maxOutputTokens: Int
    if rawMaxTokens.isEmpty {
      maxOutputTokens = EnvDefaults.maxOutputTokens
    } else if let parsedMaxTokens = Int(rawMaxTokens), parsedMaxTokens > 0 {
      maxOutputTokens = parsedMaxTokens
    } else {
      throw ConfigError.invalidMaxTokens(rawMaxTokens)
    }

    return LLMConfig(
      baseURL: baseURL,
      model: model,
      apiKey: "",  // injected at the composition root from Secrets (LLMConfig.withAPIKey)
      maxTokensField: maxTokensField,
      maxOutputTokens: maxOutputTokens,
      retryBudget: EnvDefaults.retryBudget,
      requestTimeoutSeconds: EnvDefaults.requestTimeoutSeconds,
      streamingEnabled: try boolValue(
        env[EnvKey.llmStreaming],
        key: EnvKey.llmStreaming,
        default: true
      )
    )
  }

  /// The spend budget mirrors `RunBudget.default`, except the four USD/ceiling knobs are env
  /// overridable and `maxOutputTokens`/`retryBudget` mirror `llm` (the single source of truth for
  /// those). Any present override must parse to a positive value, else fail-closed.
  private static func parseBudget(
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
  private static func positiveBudgetDouble(
    _ raw: String?,
    default fallback: Double
  ) throws -> Double {
    let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !trimmed.isEmpty else {
      return fallback
    }

    guard let value = Double(trimmed), value > 0 else {
      throw ConfigError.invalidBudget(trimmed)
    }

    return value
  }

  /// A positive `Int` override: `fallback` when absent/blank, else `invalidBudget` on a
  /// non-numeric or non-positive value.
  private static func positiveBudgetInt(_ raw: String?, default fallback: Int) throws -> Int {
    let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !trimmed.isEmpty else {
      return fallback
    }

    guard let value = Int(trimmed), value > 0 else {
      throw ConfigError.invalidBudget(trimmed)
    }

    return value
  }

  /// An optional positive `Int` ceiling override; `nil` when absent so the budget derives it.
  private static func positiveBudgetIntOrNil(_ raw: String?) throws -> Int? {
    let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !trimmed.isEmpty else {
      return nil
    }

    guard let value = Int(trimmed), value > 0 else {
      throw ConfigError.invalidBudget(trimmed)
    }

    return value
  }

  /// The scheduling timezone: absent/blank falls back to the host's current zone; a present
  /// value must resolve via `TimeZone(identifier:)`, else fail-closed.
  private static func parseTimezone(from raw: String?) throws -> TimeZone {
    let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !trimmed.isEmpty else {
      return TimeZone.current
    }

    guard let zone = TimeZone(identifier: trimmed) else {
      throw ConfigError.invalidTimezone(trimmed)
    }

    return zone
  }

  /// An `Int` override with a lower bound: `fallback` when absent/blank, else
  /// `invalidScheduling` on a non-numeric or below-minimum value.
  private static func boundedInt(
    _ raw: String?,
    key: String,
    default fallback: Int,
    minimum: Int
  ) throws -> Int {
    let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !trimmed.isEmpty else {
      return fallback
    }

    guard let value = Int(trimmed), value >= minimum else {
      throw ConfigError.invalidScheduling(key: key, value: trimmed)
    }

    return value
  }

  private static func parseQuietHours(from raw: String?) throws -> QuietHours {
    let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""

    if trimmed.isEmpty {
      if let fallback = QuietHours.parse(EnvDefaults.heartbeatQuietHours) {
        return fallback
      }
      throw ConfigError.invalidQuietHours(EnvDefaults.heartbeatQuietHours)
    }

    guard let window = QuietHours.parse(trimmed) else {
      throw ConfigError.invalidQuietHours(trimmed)
    }

    return window
  }

  private static func boolValue(
    _ raw: String?,
    key: String,
    default fallback: Bool
  ) throws -> Bool {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else {
      return fallback
    }

    switch trimmed.lowercased() {
    case "1", "true", "yes", "on":
      return true
    case "0", "false", "no", "off":
      return false
    default:
      throw ConfigError.invalidBool(key: key, value: trimmed)
    }
  }

  private static func parseAllowlist(from environmentValue: String?) throws -> Set<Int64> {
    guard
      let environmentValue = environmentValue?.trimmingCharacters(in: .whitespaces),
      !environmentValue.isEmpty
    else {
      return []
    }

    var allowlist = Set<Int64>()

    for part in environmentValue.split(separator: ",") {
      let trimmed = part.trimmingCharacters(in: .whitespaces)

      guard let id = Int64(trimmed) else {
        throw ConfigError.invalidAllowlist(trimmed)
      }

      allowlist.insert(id)
    }

    return allowlist
  }

  private static func createStateRootURL(for rawPath: String?) throws -> URL {
    let trimmedPath = rawPath?.trimmingCharacters(in: .whitespaces)
    let stateRootURL =
      if let path = trimmedPath, !path.isEmpty {
        URL(fileURLWithPath: path, isDirectory: true)
      } else {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          EnvDefaults.stateDirectoryName
        )
      }

    do {
      try FileManager.default.createDirectory(
        at: stateRootURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: stateRootPermissions]
      )
    } catch {
      throw ConfigError.unwritableStateRoot(stateRootURL.path)
    }

    return stateRootURL
  }
}
