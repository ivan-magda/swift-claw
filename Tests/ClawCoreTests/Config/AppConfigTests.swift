import Foundation
import Testing

@testable import ClawCore

@Suite struct AppConfigTests {
  private typealias EnvKey = AppConfig.EnvKey

  /// Adds the LLM keys every successful `load` now requires, unless the base already sets them.
  /// No secret keys here — the bot token / LLM key load via `SecretStore`, not `AppConfig`.
  private func envWithLLM(_ base: [String: String]) -> [String: String] {
    base.merging([
      EnvKey.llmBaseURL: "http://localhost:1234/v1",
      EnvKey.llmModel: "gpt-4o",
    ]) { existing, _ in existing }
  }

  @Test func loadsValidConfig() throws {
    // given
    let env = envWithLLM([
      EnvKey.allowlist: "42, 99",
      EnvKey.stateRoot: NSTemporaryDirectory(),
      EnvKey.pollTimeout: "20",
    ])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.allowlist == [42, 99])
    #expect(config.pollTimeoutSeconds == 20)
    #expect(config.llm.model == "gpt-4o")
    #expect(config.llm.apiKey.isEmpty)  // the secret is injected at the root, not parsed here
  }

  @Test(arguments: [
    (
      "missingLLMBaseURL",
      envWithLLM: false,
      overrides: [EnvKey.llmModel: "gpt-4o"],
      expectedError: ConfigError.missingLLMBaseURL
    ),
    (
      "invalidAllowlist",
      envWithLLM: true,
      overrides: [EnvKey.allowlist: "42, notanumber"],
      expectedError: ConfigError.invalidAllowlist("notanumber")
    ),
  ]) func missingOrInvalidConfigFieldThrows(
    description: String,
    envWithLLM: Bool,
    overrides: [String: String],
    expectedError: ConfigError
  ) {
    // given
    var env = [EnvKey.stateRoot: NSTemporaryDirectory()]
    if envWithLLM {
      env[EnvKey.llmBaseURL] = "http://localhost:1234/v1"
      env[EnvKey.llmModel] = "gpt-4o"
    }
    env.merge(overrides) { _, new in new }

    // then
    #expect(throws: expectedError) {
      _ = try AppConfig.load(environment: env)
    }
  }

  @Test func emptyAllowlistIsAllowed() throws {
    // given
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.allowlist.isEmpty)
  }

  @Test func defaultsPollTimeoutTo30() throws {
    // given
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.pollTimeoutSeconds == 30)
  }

  @Test func blankStateRootFallsBackToHomeDefaultNotCwd() throws {
    // given — copying .env.example verbatim leaves CLAW_STATE_ROOT blank
    let blankEnv = envWithLLM([EnvKey.stateRoot: "   "])
    let omittedEnv = envWithLLM([:])

    // when
    let fromBlank = try AppConfig.load(environment: blankEnv)
    let fromOmitted = try AppConfig.load(environment: omittedEnv)

    // then — a blank value resolves like an absent one (home default), never the working dir
    let workingDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    #expect(fromBlank.stateRoot == fromOmitted.stateRoot)
    #expect(fromBlank.stateRoot.standardizedFileURL != workingDir.standardizedFileURL)
  }

  @Test func loadsLLMConfigWithDefaults() throws {
    // given — only the required LLM keys, no field/max-tokens overrides
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.llm.maxTokensField == .maxCompletionTokens)
    #expect(config.llm.maxOutputTokens == 4096)
  }

  @Test func maxTokensFieldOverrideParses() throws {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.llmMaxTokensField] = "max_tokens"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.llm.maxTokensField == .maxTokens)
  }

  @Test func perDayUSDOverrideParses() throws {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.perDayUSD] = "5"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.budget.perDayUSD == 5)
  }

  @Test func budgetDefaultsMirrorRunBudgetAndLLM() throws {
    // given
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.budget.perDayUSD == RunBudget.default.perDayUSD)
    #expect(config.budget.maxOutputTokens == config.llm.maxOutputTokens)
    #expect(config.budget.dayTokenCeilingOverride == nil)
  }

  @Test func invalidBudgetValueThrows() {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.perRunUSD] = "-1"

    // when / then
    #expect(throws: ConfigError.invalidBudget("-1")) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func withAPIKeyInjectsSecretWithoutMutatingTheRest() throws {
    // given
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    let config = try AppConfig.load(environment: env)

    // when
    let withKey = config.llm.withAPIKey("sk-injected")

    // then
    #expect(withKey.apiKey == "sk-injected")
    #expect(withKey.model == config.llm.model)
    #expect(withKey.baseURL == config.llm.baseURL)
  }

  @Test func streamingDefaultsToOn() throws {
    // given
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.llm.streamingEnabled)
  }

  @Test(arguments: ["false", "FALSE", "0", "no", "off"])
  func streamingCanBeDisabled(rawValue: String) throws {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.llmStreaming] = rawValue

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.llm.streamingEnabled == false)
  }

  @Test(arguments: ["true", "TRUE", "1", "yes", "on"])
  func streamingCanBeEnabledExplicitly(rawValue: String) throws {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.llmStreaming] = rawValue

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.llm.streamingEnabled)
  }

  @Test func invalidStreamingFlagFailsClosed() {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.llmStreaming] = "sometimes"

    // then
    #expect(throws: ConfigError.invalidBool(key: EnvKey.llmStreaming, value: "sometimes")) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func schedulerAndHeartbeatDefaultsArePinned() throws {
    // given — none of the eight Inc 4 keys set
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])

    // when
    let config = try AppConfig.load(environment: env)

    // then — spec §13 defaults
    #expect(config.timezone == TimeZone.current)
    #expect(config.schedCatchUpMaxAgeMinutes == 30)
    #expect(config.schedMinIntervalMinutes == 5)
    #expect(config.proactivePerDayUSD == 2.00)
    #expect(config.heartbeatEnabled == false)
    #expect(config.heartbeatIntervalMinutes == 60)
    #expect(config.heartbeatQuietHours == QuietHours.parse("22:00-09:00"))
    #expect(config.heartbeatMaxPerDay == 8)
  }

  @Test func schedulerOverridesParse() throws {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.timezone] = "Europe/Berlin"
    env[EnvKey.schedCatchUpMaxAgeMinutes] = "45"
    env[EnvKey.schedMinIntervalMinutes] = "10"
    env[EnvKey.proactivePerDayUSD] = "1.50"
    env[EnvKey.allowlist] = "777"
    env[EnvKey.heartbeatEnabled] = "true"
    env[EnvKey.heartbeatIntervalMinutes] = "30"
    env[EnvKey.heartbeatQuietHours] = "23:30-06:15"
    env[EnvKey.heartbeatMaxPerDay] = "4"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.timezone.identifier == "Europe/Berlin")
    #expect(config.schedCatchUpMaxAgeMinutes == 45)
    #expect(config.schedMinIntervalMinutes == 10)
    #expect(config.proactivePerDayUSD == 1.50)
    #expect(config.heartbeatEnabled)
    #expect(config.heartbeatIntervalMinutes == 30)
    #expect(config.heartbeatQuietHours.rendered == "23:30-06:15")
    #expect(config.heartbeatMaxPerDay == 4)
  }

  @Test(arguments: [
    (allowlist: "", count: 0),
    (allowlist: "1,2", count: 2),
  ])
  func heartbeatEnabledWithoutOneOwnerFailsClosed(_ fixture: (allowlist: String, count: Int)) {
    // given — the heartbeat's delivery target is the config-resolved owner DM (spec §12)
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.heartbeatEnabled] = "true"
    env[EnvKey.allowlist] = fixture.allowlist

    // when / then
    #expect(
      throws: ConfigError.heartbeatOwnerUnresolved(allowlistCount: fixture.count)
    ) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func heartbeatEnabledWithExactlyOneOwnerLoads() throws {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.heartbeatEnabled] = "true"
    env[EnvKey.allowlist] = "42"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.heartbeatEnabled)
    #expect(config.allowlist == [42])
  }

  @Test func heartbeatDisabledToleratesAnyAllowlist() throws {
    // given — the default-OFF path must not constrain onboarding (empty allowlist still boots)
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.heartbeatEnabled == false)
    #expect(config.allowlist.isEmpty)
  }

  @Test func invalidTimezoneFailsClosed() {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.timezone] = "Mars/Olympus_Mons"

    // when / then
    #expect(throws: ConfigError.invalidTimezone("Mars/Olympus_Mons")) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func zeroWidthQuietHoursFailClosed() {
    // given — the OpenClaw always-skipped footgun is a config ERROR here (spec §12)
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.heartbeatQuietHours] = "22:00-22:00"

    // when / then
    #expect(throws: ConfigError.invalidQuietHours("22:00-22:00")) {
      try AppConfig.load(environment: env)
    }
  }

  @Test(arguments: [
    (key: AppConfig.EnvKey.schedCatchUpMaxAgeMinutes, value: "0"),
    (key: AppConfig.EnvKey.schedMinIntervalMinutes, value: "0"),
    (key: AppConfig.EnvKey.heartbeatIntervalMinutes, value: "14"),  // floor is 15 (spec §13)
    (key: AppConfig.EnvKey.heartbeatMaxPerDay, value: "0"),
    (key: AppConfig.EnvKey.schedCatchUpMaxAgeMinutes, value: "soon"),
  ])
  func outOfRangeSchedulingValuesFailClosed(_ fixture: (key: String, value: String)) {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[fixture.key] = fixture.value

    // when / then
    #expect(throws: ConfigError.invalidScheduling(key: fixture.key, value: fixture.value)) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func nonPositiveProactiveBudgetFailsClosed() {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.proactivePerDayUSD] = "0"

    // when / then — reuses the budget-value vocabulary (it IS a budget knob)
    #expect(throws: ConfigError.invalidBudget("0")) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func budgetMirrorsTheProactivePerDayCap() throws {
    // given — the env key Phase 1 already parses onto AppConfig.proactivePerDayUSD
    let env = envWithLLM([
      EnvKey.stateRoot: NSTemporaryDirectory(),
      "CLAW_PROACTIVE_PER_DAY_USD": "1.25",
    ])

    // when
    let config = try AppConfig.load(environment: env)

    // then — one value, two views: the AppConfig field (Phase 1) and the RunBudget mirror (here)
    #expect(config.budget.proactivePerDayUSD == 1.25)
    #expect(config.proactivePerDayUSD == 1.25)
  }
}
