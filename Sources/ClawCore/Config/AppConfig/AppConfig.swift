import Foundation

public struct AppConfig: Sendable, Equatable {
  public enum EnvKey {
    // MARK: - Telegram

    static let allowlist = "CLAW_ALLOWLIST"
    static let groupChats = "CLAW_GROUP_CHATS"
    static let pollTimeout = "CLAW_POLL_TIMEOUT"
    static let telegramProgress = "CLAW_TELEGRAM_PROGRESS"

    // MARK: - State storage

    public static let stateRoot = "CLAW_STATE_ROOT"

    // MARK: - Primary LLM

    static let llmBaseURL = "CLAW_LLM_BASE_URL"
    public static let llmModel = "CLAW_LLM_MODEL"
    static let llmMaxTokensField = "CLAW_LLM_MAX_TOKENS_FIELD"
    static let llmMaxTokens = "CLAW_LLM_MAX_TOKENS"
    static let llmStreaming = "CLAW_LLM_STREAMING"
    static let llmStructuredOutput = "CLAW_LLM_STRUCTURED_OUTPUT"
    public static let llmInputUSDPerMTok = "CLAW_LLM_INPUT_USD_PER_MTOK"
    public static let llmOutputUSDPerMTok = "CLAW_LLM_OUTPUT_USD_PER_MTOK"

    // MARK: - LLM fallback and recovery

    static let llmFallbackModel = "CLAW_LLM_FALLBACK_MODEL"
    static let llmFallbackBaseURL = "CLAW_LLM_FALLBACK_BASE_URL"
    static let llmFallbackMaxTokensField = "CLAW_LLM_FALLBACK_MAX_TOKENS_FIELD"
    public static let llmFallbackInputUSDPerMTok = "CLAW_LLM_FALLBACK_INPUT_USD_PER_MTOK"
    public static let llmFallbackOutputUSDPerMTok = "CLAW_LLM_FALLBACK_OUTPUT_USD_PER_MTOK"
    static let llmPrimaryCooldownSeconds = "CLAW_LLM_PRIMARY_COOLDOWN_SECONDS"

    // MARK: - Budget limits

    static let perRunUSD = "CLAW_PER_RUN_USD"
    static let perDayUSD = "CLAW_PER_DAY_USD"
    static let referenceUSDPerToken = "CLAW_REFERENCE_USD_PER_TOKEN"
    static let dayTokenCeiling = "CLAW_DAY_TOKEN_CEILING"

    // MARK: - Agent run limits

    static let maxTurns = "CLAW_MAX_TURNS"
    static let maxToolCalls = "CLAW_MAX_TOOL_CALLS"

    // MARK: - Scheduling

    static let timezone = "CLAW_TIMEZONE"
    static let schedCatchUpMaxAgeMinutes = "CLAW_SCHED_CATCHUP_MAX_AGE_MINUTES"
    static let schedMinIntervalMinutes = "CLAW_SCHED_MIN_INTERVAL_MINUTES"
    static let proactivePerDayUSD = "CLAW_PROACTIVE_PER_DAY_USD"

    // MARK: - Heartbeat

    static let heartbeatEnabled = "CLAW_HEARTBEAT_ENABLED"
    static let heartbeatIntervalMinutes = "CLAW_HEARTBEAT_INTERVAL_MINUTES"
    static let heartbeatQuietHours = "CLAW_HEARTBEAT_QUIET_HOURS"
    static let heartbeatMaxPerDay = "CLAW_HEARTBEAT_MAX_PER_DAY"

    // MARK: - Approvals

    static let approvalExpiry = "CLAW_APPROVAL_EXPIRY"

    // MARK: - Learning

    public static let learningEnabled = "CLAW_LEARNING_ENABLED"

    // MARK: - Web fetch

    public static let webFetchExemptCIDRs = "CLAW_WEBFETCH_EXEMPT_CIDRS"

    // MARK: - Voice input

    static let voiceTranscription = "CLAW_VOICE_TRANSCRIPTION"
    static let voiceLocales = "CLAW_VOICE_LOCALES"

    // MARK: - Image input

    static let imageInput = "CLAW_IMAGE_INPUT"

    // MARK: - Sandbox execution

    static let execEnabled = "CLAW_EXEC_ENABLED"
    static let execImage = "CLAW_EXEC_IMAGE"
    static let execImageRegistries = "CLAW_EXEC_IMAGE_REGISTRIES"
    static let execMemoryMiB = "CLAW_EXEC_MEMORY_MIB"
    static let execCPUs = "CLAW_EXEC_CPUS"
    static let execTimeout = "CLAW_EXEC_TIMEOUT"
    static let execAllowEgress = "CLAW_EXEC_ALLOW_EGRESS"

    // MARK: - Native Coder

    public static let coderEnabled = "CLAW_CODER_ENABLED"
    public static let coderMaxConcurrentJobs = "CLAW_CODER_MAX_CONCURRENT_JOBS"
    public static let coderJobTimeoutSeconds = "CLAW_CODER_JOB_TIMEOUT_SECONDS"
    public static let coderExecutable = "CLAW_CODER_EXECUTABLE"
    public static let coderPath = "CLAW_CODER_PATH"
    public static let coderProfile = "CLAW_CODER_PROFILE"
    public static let coderConfigHome = "CLAW_CODER_CONFIG_HOME"

    // MARK: - MCP

    static let mcpConfigPath = "CLAW_MCP_CONFIG"
  }

  enum EnvDefaults {
    // MARK: - Telegram

    static let pollTimeoutSeconds = 30

    // MARK: - LLM requests and recovery

    static let maxTokensField = MaxTokensField.maxCompletionTokens
    static let structuredOutput = StructuredOutputMode.off
    static let maxOutputTokens = RunDefaults.maxOutputTokens
    static let retryBudget = RunDefaults.retryBudget
    static let requestTimeoutSeconds = 180
    static let primaryCooldownSeconds = 900

    // MARK: - Scheduling

    static let schedCatchUpMaxAgeMinutes = 30
    static let schedMinIntervalMinutes = 5
    static let proactivePerDayUSD = RunDefaults.proactivePerDayUSD

    // MARK: - Heartbeat

    static let heartbeatIntervalMinutes = 60
    static let heartbeatQuietHours = "22:00-09:00"
    static let heartbeatMaxPerDay = 8

    // MARK: - Approvals

    static let approvalExpirySeconds = 3600
    static let approvalExpiryFloor = 60
    static let approvalExpiryCeiling = 86_400

    // MARK: - Voice input

    public static let voiceLocale = "en-US"

    // MARK: - Sandbox execution

    static let execImageRegistries = ["cgr.dev"]
    static let execMemoryMiB = 1024
    static let execCPUs = 4
    static let execTimeoutSeconds = 30
  }

  // MARK: - Telegram

  public let allowlist: Set<Int64>
  /// The chat ids group mode serves. Empty means group mode is off and `clawd` answers only the
  /// owner's DM.
  public let groupChats: Set<Int64>
  public let pollTimeoutSeconds: Int
  public let telegramProgressEnabled: Bool

  // MARK: - State storage

  public let stateRoot: URL

  // MARK: - LLM and budget

  public let llm: LLMConfig
  public let budget: RunBudget

  // MARK: - Scheduling

  public let timezone: TimeZone
  public let schedCatchUpMaxAgeMinutes: Int
  public let schedMinIntervalMinutes: Int
  public let proactivePerDayUSD: Double

  // MARK: - Heartbeat

  public let heartbeatEnabled: Bool
  public let heartbeatIntervalMinutes: Int
  public let heartbeatQuietHours: QuietHours
  public let heartbeatMaxPerDay: Int

  /// The single allowlisted owner target, retained while heartbeat is off for crash reconciliation.
  public var heartbeatOwnerChatID: Int64? {
    guard allowlist.count == 1 else {
      return nil
    }
    return allowlist.first
  }

  // MARK: - Learning

  public let learningEnabled: Bool

  // MARK: - Approvals and web access

  public let approvalExpirySeconds: Int
  public let webFetchExemptCIDRs: [CIDR]

  // MARK: - Tool and input configuration

  public let coder: CoderConfig
  public let exec: ExecConfig
  public let voice: VoiceConfig
  public let image: ImageConfig
  public let mcpConfigSource: MCPConfigSource

  public init(
    allowlist: Set<Int64>,
    groupChats: Set<Int64>,
    pollTimeoutSeconds: Int,
    telegramProgressEnabled: Bool,
    stateRoot: URL,
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
    coder: CoderConfig,
    exec: ExecConfig,
    voice: VoiceConfig,
    image: ImageConfig,
    mcpConfigSource: MCPConfigSource
  ) {
    self.allowlist = allowlist
    self.groupChats = groupChats
    self.pollTimeoutSeconds = pollTimeoutSeconds
    self.telegramProgressEnabled = telegramProgressEnabled

    self.stateRoot = stateRoot

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

    self.coder = coder
    self.exec = exec
    self.voice = voice
    self.image = image
    self.mcpConfigSource = mcpConfigSource
  }

  /// Loads and validates non-secret config from the environment. Secrets (the bot token / LLM key)
  /// are loaded separately via `SecretStore` and injected at the composition root. An empty
  /// allowlist is allowed so onboarding can still boot.
  public static func load(environment env: [String: String]) throws -> AppConfig {
    let allowlist = try parseIDSet(
      from: env[EnvKey.allowlist],
      invalid: ConfigError.invalidAllowlist
    )
    let groupChats = try parseIDSet(
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
      pollTimeoutSeconds: pollTimeoutSeconds,
      telegramProgressEnabled: try boolValue(
        env[EnvKey.telegramProgress],
        key: EnvKey.telegramProgress,
        default: true
      ),
      stateRoot: stateRoot,
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
      coder: try CoderConfig.load(environment: env),
      exec: exec,
      voice: voice,
      image: image,
      mcpConfigSource: mcpConfigSource
    )
  }
}

// MARK: - MCP Config Location

extension AppConfig {
  /// Resolves *where* the MCP catalog lives, not whether it is readable — the loader owns that, and
  /// the two answers differ: an owner-named path that is missing fails the boot, while the probed
  /// default being missing is just the feature staying off.
  ///
  /// Public because the CLI verbs that manage MCP tokens need the catalog's location without the
  /// rest of the daemon's configuration having to be valid: an owner repairing a token must not be
  /// stopped by an unrelated env var.
  public static func mcpConfigSource(
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
  ) throws(ConfigError) -> Bool {
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
  static func parseIDSet(
    from environmentValue: String?,
    invalid: (_ value: String) -> ConfigError
  ) throws -> Set<Int64> {
    guard let environmentValue = environmentValue?.trimmingCharacters(in: .whitespaces),
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

    return
      try trimmed
      .split(separator: ",")
      .map { part in
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
