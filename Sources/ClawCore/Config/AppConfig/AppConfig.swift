import Foundation

public struct AppConfig: Sendable, Equatable {
  public enum EnvKey {
    static let allowlist = "CLAW_ALLOWLIST"
    static let groupChats = "CLAW_GROUP_CHATS"
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

    static let llmFallbackModel = "CLAW_LLM_FALLBACK_MODEL"
    static let llmFallbackBaseURL = "CLAW_LLM_FALLBACK_BASE_URL"
    static let llmFallbackMaxTokensField = "CLAW_LLM_FALLBACK_MAX_TOKENS_FIELD"
    static let primaryCooldownSeconds = "CLAW_LLM_PRIMARY_COOLDOWN_SECONDS"

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

    public static let learningEnabled = "CLAW_LEARNING_ENABLED"

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

    static let mcpConfigPath = "CLAW_MCP_CONFIG"
  }

  enum EnvDefaults {
    static let pollTimeoutSeconds = 30
    static let maxTokensField = MaxTokensField.maxCompletionTokens
    static let structuredOutput = StructuredOutputMode.off
    static let maxOutputTokens = RunDefaults.maxOutputTokens
    static let retryBudget = RunDefaults.retryBudget
    static let requestTimeoutSeconds = 180
    static let primaryCooldownSeconds = 900

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
  /// The chat ids group mode serves. Empty means group mode is off and `clawd` answers only the
  /// owner's DM.
  public let groupChats: Set<Int64>
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

  /// The single allowlisted owner target, retained while heartbeat is off for crash reconciliation.
  public var heartbeatOwnerChatId: Int64? {
    guard allowlist.count == 1 else {
      return nil
    }
    return allowlist.first
  }

  /// Arms the scheduled-task learning loop. Off by default: with it unset no binding is created
  /// and no learning row is written, so the daemon behaves exactly as it does without the feature.
  public let learningEnabled: Bool

  public let approvalExpirySeconds: Int
  public let webFetchExemptCIDRs: [CIDR]
  public let exec: ExecConfig
  public let voice: VoiceConfig
  public let image: ImageConfig
  public let mcpConfigSource: MCPConfigSource

  public init(
    allowlist: Set<Int64>,
    groupChats: Set<Int64>,
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
    learningEnabled: Bool,
    approvalExpirySeconds: Int,
    webFetchExemptCIDRs: [CIDR],
    exec: ExecConfig,
    voice: VoiceConfig,
    image: ImageConfig,
    mcpConfigSource: MCPConfigSource
  ) {
    self.allowlist = allowlist
    self.groupChats = groupChats
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

    self.learningEnabled = learningEnabled

    self.approvalExpirySeconds = approvalExpirySeconds
    self.webFetchExemptCIDRs = webFetchExemptCIDRs
    self.exec = exec
    self.voice = voice
    self.image = image
    self.mcpConfigSource = mcpConfigSource
  }

  /// Loads and validates non-secret config from the environment. Secrets (the bot token / LLM key)
  /// are loaded separately via `SecretStore` and injected at the composition root. An empty
  /// allowlist is allowed so onboarding can still boot.
  public static func load(environment env: [String: String]) throws -> AppConfig {
    let allowlist = try parseIdSet(
      from: env[EnvKey.allowlist],
      invalid: ConfigError.invalidAllowlist
    )
    let groupChats = try parseIdSet(
      from: env[EnvKey.groupChats],
      invalid: ConfigError.invalidGroupChats
    )
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
    let mcpConfigSource = Self.mcpConfigSource(from: env, stateRoot: stateRoot)

    return AppConfig(
      allowlist: allowlist,
      groupChats: groupChats,
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
      learningEnabled: try parseLearningEnabled(from: env),
      approvalExpirySeconds: approvalExpirySeconds,
      webFetchExemptCIDRs: webFetchExemptCIDRs,
      exec: exec,
      voice: voice,
      image: image,
      mcpConfigSource: mcpConfigSource
    )
  }
}

// MARK: - MCP Config Location

public extension AppConfig {
  /// Resolves *where* the MCP catalog lives, not whether it is readable — the loader owns that, and
  /// the two answers differ: an owner-named path that is missing fails the boot, while the probed
  /// default being missing is just the feature staying off.
  ///
  /// Public because the CLI verbs that manage MCP tokens need the catalog's location without the
  /// rest of the daemon's configuration having to be valid: an owner repairing a token must not be
  /// stopped by an unrelated env var.
  static func mcpConfigSource(
    from env: [String: String],
    stateRoot: URL
  ) -> MCPConfigSource {
    let raw = env[EnvKey.mcpConfigPath]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard raw.isEmpty == false else {
      return .probed(stateRoot.appendingPathComponent(MCPLimits.configFileName))
    }
    return .explicit(URL(fileURLWithPath: raw))
  }
}

// MARK: - Scheduled Learning Enablement

private extension AppConfig {
  static func parseLearningEnabled(from env: [String: String]) throws -> Bool {
    try boolValue(env[EnvKey.learningEnabled], key: EnvKey.learningEnabled, default: false)
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

// MARK: - Numeric Id Sets

private extension AppConfig {
  /// Parses one comma-separated list of Telegram ids. The caller names the error so a bad entry
  /// points at the variable it came from; both lists share this parser so they can never disagree
  /// about whitespace or emptiness.
  static func parseIdSet(
    from environmentValue: String?,
    invalid: (String) -> ConfigError
  ) throws -> Set<Int64> {
    guard
      let environmentValue = environmentValue?.trimmingCharacters(in: .whitespaces),
      !environmentValue.isEmpty
    else {
      return []
    }

    var ids = Set<Int64>()

    for part in environmentValue.split(separator: ",") {
      let trimmed = part.trimmingCharacters(in: .whitespaces)

      guard let id = Int64(trimmed) else {
        throw invalid(trimmed)
      }

      ids.insert(id)
    }

    return ids
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
