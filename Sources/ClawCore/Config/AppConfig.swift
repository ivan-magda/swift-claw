import Foundation

public struct AppConfig: Sendable, Equatable {
  public enum EnvKey {
    static let allowlist = "CLAW_ALLOWLIST"
    /// Public because the auth commands resolve the same state root without loading this config.
    /// The daemon and `clawd auth` have to read the one variable, or they diverge on where an
    /// owner's credentials live.
    public static let stateRoot = "CLAW_STATE_ROOT"
    static let pollTimeout = "CLAW_POLL_TIMEOUT"

    static let llmBaseURL = "CLAW_LLM_BASE_URL"
    /// Public because login prints the assignment an owner must set. The variable it names and the
    /// variable configuration reads have to be the same word.
    public static let llmModel = "CLAW_LLM_MODEL"
    static let llmMaxTokensField = "CLAW_LLM_MAX_TOKENS_FIELD"
    static let llmMaxTokens = "CLAW_LLM_MAX_TOKENS"
    static let llmStreaming = "CLAW_LLM_STREAMING"
    static let llmStructuredOutput = "CLAW_LLM_STRUCTURED_OUTPUT"

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
    static let approvalExpiry = "CLAW_APPROVAL_EXPIRY"

    public static let webFetchExemptCIDRs = "CLAW_WEBFETCH_EXEMPT_CIDRS"

    static let voiceTranscription = "CLAW_VOICE_TRANSCRIPTION"
    static let voiceLocales = "CLAW_VOICE_LOCALES"

    static let imageInput = "CLAW_IMAGE_INPUT"

    static let execEnabled = "CLAW_EXEC_ENABLED"
    static let execImage = "CLAW_EXEC_IMAGE"
    static let execImageRegistries = "CLAW_EXEC_IMAGE_REGISTRIES"
    static let execMemoryMiB = "CLAW_EXEC_MEMORY_MIB"
    static let execCPUs = "CLAW_EXEC_CPUS"
    static let execTimeout = "CLAW_EXEC_TIMEOUT"
    static let execAllowEgress = "CLAW_EXEC_ALLOW_EGRESS"
  }

  enum EnvDefaults {
    static let pollTimeoutSeconds = 30
    static let maxTokensField = MaxTokensField.maxCompletionTokens
    static let structuredOutput = StructuredOutputMode.off
    static let maxOutputTokens = RunDefaults.maxOutputTokens
    static let retryBudget = RunDefaults.retryBudget
    static let requestTimeoutSeconds = 180

    static let schedCatchUpMaxAgeMinutes = 30
    static let schedMinIntervalMinutes = 5
    static let proactivePerDayUSD = RunDefaults.proactivePerDayUSD

    static let heartbeatIntervalMinutes = 60
    static let heartbeatQuietHours = "22:00-09:00"
    static let heartbeatMaxPerDay = 8

    static let approvalExpirySeconds = 3600
    static let approvalExpiryFloor = 60
    static let approvalExpiryCeiling = 86_400

    public static let voiceLocale = "en-US"

    static let execImageRegistries = ["cgr.dev"]
    static let execMemoryMiB = 1024
    static let execCPUs = 4
    static let execTimeoutSeconds = 30
  }

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

  public let approvalExpirySeconds: Int
  public let webFetchExemptCIDRs: [CIDR]
  public let exec: ExecConfig
  public let voice: VoiceConfig
  public let image: ImageConfig

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
    heartbeatMaxPerDay: Int,
    approvalExpirySeconds: Int,
    webFetchExemptCIDRs: [CIDR],
    exec: ExecConfig,
    voice: VoiceConfig,
    image: ImageConfig
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

    self.approvalExpirySeconds = approvalExpirySeconds
    self.webFetchExemptCIDRs = webFetchExemptCIDRs
    self.exec = exec
    self.voice = voice
    self.image = image
  }

  /// Loads and validates non-secret config from the environment. Secrets (the bot token / LLM key)
  /// are loaded separately via `SecretStore` and injected at the composition root. An empty
  /// allowlist is allowed so onboarding can still boot.
  public static func load(environment env: [String: String]) throws -> AppConfig {
    let allowlist = try parseAllowlist(from: env[EnvKey.allowlist])
    let stateRoot = try StateRootResolver.createStateRoot(for: env[EnvKey.stateRoot])
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
    let heartbeat = try parseHeartbeat(from: env, allowlist: allowlist)

    let approvalExpirySeconds = try parseApprovalExpiry(env[EnvKey.approvalExpiry])
    let webFetchExemptCIDRs = try parseWebFetchExemptCIDRs(from: env[EnvKey.webFetchExemptCIDRs])
    let exec = try parseExecConfig(from: env)
    let voice = try parseVoiceConfig(from: env)
    let image = try parseImageConfig(from: env)

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
      heartbeatEnabled: heartbeat.enabled,
      heartbeatIntervalMinutes: heartbeat.intervalMinutes,
      heartbeatQuietHours: heartbeat.quietHours,
      heartbeatMaxPerDay: heartbeat.maxPerDay,
      approvalExpirySeconds: approvalExpirySeconds,
      webFetchExemptCIDRs: webFetchExemptCIDRs,
      exec: exec,
      voice: voice,
      image: image
    )
  }
}

// MARK: - LLM Config Parsing

private extension AppConfig {
  /// Resolves the route from the model first, so a managed model that names no base URL is not
  /// rejected for lacking one it never uses. The base URL is an autoclosure the registry evaluates
  /// only for the current route, and the wire output-token field is applied only where the route
  /// honors one — the managed ChatGPT route ignores `CLAW_LLM_MAX_TOKENS_FIELD` because it carries no
  /// wire cap. The API key is not read here: it is a secret the composition root hands a credential
  /// source.
  static func parseLLMConfig(from env: [String: String]) throws -> LLMConfig {
    guard
      let model = env[EnvKey.llmModel]?.trimmingCharacters(in: .whitespaces),
      !model.isEmpty
    else {
      throw ConfigError.missingLLMModel
    }

    let resolved = try LLMProviderRegistry.resolve(
      modelReference: model,
      configuredBaseURL: try requiredBaseURL(from: env)
    )
    let route = try routeApplyingWireOutputField(to: resolved, env: env)

    let rawMaxTokens = env[EnvKey.llmMaxTokens]?.trimmingCharacters(in: .whitespaces) ?? ""
    let maxOutputTokens: Int
    if rawMaxTokens.isEmpty {
      maxOutputTokens = EnvDefaults.maxOutputTokens
    } else if let parsedMaxTokens = Int(rawMaxTokens), parsedMaxTokens > 0 {
      maxOutputTokens = parsedMaxTokens
    } else {
      throw ConfigError.invalidMaxTokens(rawMaxTokens)
    }

    let structuredOutput = try parseStructuredOutput(from: env, route: route)

    return LLMConfig(
      route: route,
      maxOutputTokens: maxOutputTokens,
      retryBudget: EnvDefaults.retryBudget,
      requestTimeoutSeconds: EnvDefaults.requestTimeoutSeconds,
      streamingEnabled: try boolValue(
        env[EnvKey.llmStreaming],
        key: EnvKey.llmStreaming,
        default: true
      ),
      structuredOutput: structuredOutput
    )
  }

  /// The current route's required base URL, thrown lazily so the registry evaluates it only when the
  /// model resolves to that route. A managed model leaves this unevaluated, which is what lets
  /// `CLAW_LLM_BASE_URL` stay absent for it.
  static func requiredBaseURL(from env: [String: String]) throws -> String {
    guard
      let baseURL = env[EnvKey.llmBaseURL]?.trimmingCharacters(in: .whitespaces),
      !baseURL.isEmpty
    else {
      throw ConfigError.missingLLMBaseURL
    }
    return baseURL
  }

  /// Rebuilds the route's wire output-token field from `CLAW_LLM_MAX_TOKENS_FIELD`, but only when the
  /// resolved descriptor carries a configured field. A route that omits the wire cap honors no such
  /// variable, so it is neither read nor validated there — parsing it would resurrect a value the
  /// route ignores and reject a value it never consults.
  static func routeApplyingWireOutputField(
    to route: ResolvedLLMRoute,
    env: [String: String]
  ) throws -> ResolvedLLMRoute {
    guard case .configured = route.descriptor.capabilities.outputTokenField else {
      return route
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

    let capabilities = route.descriptor.capabilities
    let rebuilt = LLMProviderDescriptor(
      providerID: route.descriptor.providerID,
      qualifiedPrefix: route.descriptor.qualifiedPrefix,
      egress: route.descriptor.egress,
      credentialMode: route.descriptor.credentialMode,
      capabilities: LLMProviderCapabilities(
        supportsStructuredOutput: capabilities.supportsStructuredOutput,
        outputTokenField: .configured(maxTokensField)
      )
    )
    return ResolvedLLMRoute(
      descriptor: rebuilt,
      configuredReference: route.configuredReference,
      wireModel: route.wireModel
    )
  }

  /// Parses `CLAW_LLM_STRUCTURED_OUTPUT` and enforces the route's capability: a route with no
  /// relied-upon structured-output contract accepts only `off`, and any other value fails closed with
  /// the route named rather than being silently sent to a wire that cannot honor it.
  static func parseStructuredOutput(
    from env: [String: String],
    route: ResolvedLLMRoute
  ) throws -> StructuredOutputMode {
    let rawStructuredOutput =
      env[EnvKey.llmStructuredOutput]?.trimmingCharacters(in: .whitespaces) ?? ""
    let structuredOutput: StructuredOutputMode
    if rawStructuredOutput.isEmpty {
      structuredOutput = EnvDefaults.structuredOutput
    } else if let parsedMode = StructuredOutputMode(rawValue: rawStructuredOutput) {
      structuredOutput = parsedMode
    } else {
      throw ConfigError.invalidStructuredOutput(rawStructuredOutput)
    }

    if structuredOutput != .off, !route.descriptor.capabilities.supportsStructuredOutput {
      throw ConfigError.structuredOutputUnsupportedOnRoute(
        providerID: route.descriptor.providerID,
        mode: structuredOutput
      )
    }
    return structuredOutput
  }
}

// MARK: - Budget Parsing

private extension AppConfig {
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
    try ConfigParse.boundedIntOrNil(raw, range: 1...Int.max, onInvalid: ConfigError.invalidBudget)
  }
}

// MARK: - Scheduling & Heartbeat Parsing

private extension AppConfig {
  /// The scheduling timezone: absent/blank falls back to the host's current zone; a present
  /// value must resolve via `TimeZone(identifier:)`, else fail-closed.
  static func parseTimezone(from raw: String?) throws -> TimeZone {
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
  static func boundedInt(
    _ raw: String?,
    key: String,
    default fallback: Int,
    minimum: Int
  ) throws -> Int {
    try ConfigParse.boundedInt(raw, default: fallback, range: minimum...Int.max) { value in
      ConfigError.invalidScheduling(key: key, value: value)
    }
  }

  struct HeartbeatSettings {
    let enabled: Bool
    let intervalMinutes: Int
    let quietHours: QuietHours
    let maxPerDay: Int
  }

  static func parseHeartbeat(
    from env: [String: String],
    allowlist: Set<Int64>
  ) throws -> HeartbeatSettings {
    let enabled = try boolValue(
      env[EnvKey.heartbeatEnabled],
      key: EnvKey.heartbeatEnabled,
      default: false
    )
    // The heartbeat delivers to the config-resolved owner DM (and the same target
    // serves the boot-reconcile crash notice). Enabling it without exactly one allowlisted id
    // is a config ERROR (fail closed at load + doctor --check-config), never a runtime guess.
    if enabled, allowlist.count != 1 {
      throw ConfigError.heartbeatOwnerUnresolved(allowlistCount: allowlist.count)
    }

    return HeartbeatSettings(
      enabled: enabled,
      intervalMinutes: try boundedInt(
        env[EnvKey.heartbeatIntervalMinutes],
        key: EnvKey.heartbeatIntervalMinutes,
        default: EnvDefaults.heartbeatIntervalMinutes,
        minimum: 15
      ),
      quietHours: try parseQuietHours(from: env[EnvKey.heartbeatQuietHours]),
      maxPerDay: try boundedInt(
        env[EnvKey.heartbeatMaxPerDay],
        key: EnvKey.heartbeatMaxPerDay,
        default: EnvDefaults.heartbeatMaxPerDay,
        minimum: 1
      )
    )
  }

  static func parseQuietHours(from raw: String?) throws -> QuietHours {
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
}

// MARK: - Generic Value Parsing

extension AppConfig {
  static func boolValue(
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
}

// MARK: - Allowlist

private extension AppConfig {
  static func parseAllowlist(from environmentValue: String?) throws -> Set<Int64> {
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
}

// MARK: - Web Fetch Egress Parsing

private extension AppConfig {
  /// The comma-separated CIDR list web_fetch exempts from the SSRF blocklist. Absent/blank means
  /// no exemption; any malformed entry fails the whole load closed — a widening of the egress
  /// posture must never boot half-parsed.
  static func parseWebFetchExemptCIDRs(from raw: String?) throws -> [CIDR] {
    let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !trimmed.isEmpty else {
      return []
    }

    return try trimmed.split(separator: ",").map { part in
      let entry = part.trimmingCharacters(in: .whitespaces)
      guard let cidr = CIDR.parse(entry) else {
        throw ConfigError.invalidWebFetchExemptCIDR(entry)
      }
      return cidr
    }
  }
}

// MARK: - Approval Parsing

private extension AppConfig {
  /// Seconds a pending tool approval stays live before auto-deny; the 1-hour default and the
  /// [floor, ceiling] bounds are spec-pinned (ARCHITECTURE.md §15). Absent/blank falls back to
  /// the default; a present value
  /// must be an integer within `[floor, ceiling]`, else it fails closed with the dedicated
  /// `invalidApprovalExpiry` case — the scheduling vocabulary deliberately is NOT reused.
  static func parseApprovalExpiry(_ raw: String?) throws -> Int {
    try ConfigParse.boundedInt(
      raw,
      default: EnvDefaults.approvalExpirySeconds,
      range: EnvDefaults.approvalExpiryFloor...EnvDefaults.approvalExpiryCeiling,
      onInvalid: ConfigError.invalidApprovalExpiry
    )
  }
}
