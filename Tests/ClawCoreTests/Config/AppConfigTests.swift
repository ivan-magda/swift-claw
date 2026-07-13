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

  @Test func approvalExpiryDefaultsTo3600() throws {
    // given — the key unset
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])

    // when
    let config = try AppConfig.load(environment: env)

    // then — spec §4.6 default
    #expect(config.approvalExpirySeconds == 3600)
  }

  @Test func approvalExpiryOverrideParses() throws {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.approvalExpiry] = "1800"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.approvalExpirySeconds == 1800)
  }

  @Test func approvalExpiryFloorAndCeilingAreInclusive() throws {
    // given — the exact bounds are legal (spec §4.6: floor 60, ceiling 86400)
    var floorEnv = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    floorEnv[EnvKey.approvalExpiry] = "60"
    var ceilingEnv = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    ceilingEnv[EnvKey.approvalExpiry] = "86400"

    // when
    let floorConfig = try AppConfig.load(environment: floorEnv)
    let ceilingConfig = try AppConfig.load(environment: ceilingEnv)

    // then
    #expect(floorConfig.approvalExpirySeconds == 60)
    #expect(ceilingConfig.approvalExpirySeconds == 86400)
  }

  @Test(arguments: [
    "59",  // below the 60s floor
    "86401",  // above the 86400s ceiling
    "soon",  // non-numeric
    "0",  // zero
  ])
  func outOfRangeApprovalExpiryFailsClosed(_ rawValue: String) {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.approvalExpiry] = rawValue

    // when / then — a dedicated ConfigError case (spec §4.6), never the scheduling vocabulary
    #expect(throws: ConfigError.invalidApprovalExpiry(rawValue)) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func webFetchExemptCIDRsDefaultToEmpty() throws {
    // given — the key unset, and set but blank
    let omittedEnv = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    var blankEnv = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    blankEnv[EnvKey.webFetchExemptCIDRs] = "   "

    // when / then — no exemption unless the owner opts in explicitly
    #expect(try AppConfig.load(environment: omittedEnv).webFetchExemptCIDRs.isEmpty)
    #expect(try AppConfig.load(environment: blankEnv).webFetchExemptCIDRs.isEmpty)
  }

  @Test func webFetchExemptCIDRsParseAsAList() throws {
    // given — a fake-IP v4 pool plus a fake v6 range, comma-separated with spaces
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.webFetchExemptCIDRs] = "198.18.0.0/15, fc00::/18"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.webFetchExemptCIDRs == [CIDR.parse("198.18.0.0/15"), CIDR.parse("fc00::/18")])
  }

  @Test(arguments: [
    "junk",  // not CIDR notation
    "198.18.0.84",  // bare address without a prefix
    "198.18.0.0/33",  // prefix out of bounds
    "198.18.0.0/15, junk",  // one bad entry poisons the list
  ])
  func malformedWebFetchExemptCIDRsFailClosed(_ rawValue: String) {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.webFetchExemptCIDRs] = rawValue

    // when / then — a widening of the SSRF posture must never load half-parsed
    let badEntry = rawValue.split(separator: ",").map { part in
      part.trimmingCharacters(in: .whitespaces)
    }.first { entry in CIDR.parse(entry) == nil }
    #expect(throws: ConfigError.invalidWebFetchExemptCIDR(badEntry ?? rawValue)) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func execDefaultsToDisabledWithStableLowCoreSafeValues() throws {
    // given
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.exec == .disabledDefault)
    #expect(config.exec.enabled == false)
    #expect(config.exec.image == nil)
    #expect(config.exec.imageRegistryAllowlist == ["cgr.dev"])
    #expect(config.exec.memoryMiB == 1024)
    #expect(config.exec.cpus == 4)
    #expect(config.exec.timeoutSeconds == 30)
    #expect(config.exec.allowEgress == false)
  }

  @Test func pinnedImageParserAcceptsOnlyAnExplicitRegistryAndLowercaseDigest() throws {
    // given
    let digest = String(repeating: "a", count: 64)

    // when
    let image = try #require(
      PinnedImageReference.parse("cgr.dev/chainguard/python@sha256:\(digest)")
    )

    // then
    #expect(image.repository == "cgr.dev/chainguard/python")
    #expect(image.digest == digest)
    #expect(image.registryHost == "cgr.dev")
    #expect(image.description == "cgr.dev/chainguard/python@sha256:\(digest)")
  }

  @Test(arguments: [
    "chainguard/python@sha256:" + String(repeating: "a", count: 64),
    "https://cgr.dev/chainguard/python@sha256:" + String(repeating: "a", count: 64),
    "cgr.dev/chainguard/python:latest",
    "cgr.dev/chainguard/python@sha256:" + String(repeating: "A", count: 64),
    "localhost/python@sha256:" + String(repeating: "a", count: 64),
    "127.0.0.1/python@sha256:" + String(repeating: "a", count: 64),
    "éxample.com/python@sha256:" + String(repeating: "a", count: 64),
    "cgr.dev/pythön@sha256:" + String(repeating: "a", count: 64),
    "cgr.dev:+443/python@sha256:" + String(repeating: "a", count: 64),
    "cgr.dev/python@sha256:abc",
    " cgr.dev/python@sha256:" + String(repeating: "a", count: 64),
  ])
  func pinnedImageParserRejectsAmbiguousOrUntrustedReferences(_ rawValue: String) {
    // given / when / then
    #expect(PinnedImageReference.parse(rawValue) == nil)
  }

  @Test func enabledExecParsesTheCompleteValidatedBlock() throws {
    // given
    let digest = String(repeating: "b", count: 64)
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.execEnabled] = "true"
    env[EnvKey.execImage] = "images.example.com/team/python@sha256:\(digest)"
    env[EnvKey.execImageRegistries] = "CGR.DEV, images.example.com, cgr.dev"
    env[EnvKey.execMemoryMiB] = "512"
    env[EnvKey.execCPUs] = "1"
    env[EnvKey.execTimeout] = "45"
    env[EnvKey.execAllowEgress] = "true"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.exec.enabled)
    #expect(
      config.exec.image?.description
        == "images.example.com/team/python@sha256:\(digest)"
    )
    #expect(config.exec.imageRegistryAllowlist == ["cgr.dev", "images.example.com"])
    #expect(config.exec.memoryMiB == 512)
    #expect(config.exec.cpus == 1)
    #expect(config.exec.timeoutSeconds == 45)
    #expect(config.exec.allowEgress)
  }

  @Test func disabledExecDoesNotApplyTheLiveHostCPUCeiling() throws {
    // given: Linux CI may expose fewer than four CPUs; disabled parsing must remain stable
    let aboveHost = ProcessInfo.processInfo.activeProcessorCount + 1
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.execCPUs] = "\(aboveHost)"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.exec.enabled == false)
    #expect(config.exec.cpus == aboveHost)
  }

  @Test func enabledExecDefaultsToTheVerifiedImagePin() throws {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.execEnabled] = "true"
    env[EnvKey.execCPUs] = "1"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.exec.enabled)
    #expect(config.exec.image == .verifiedDefault)
  }

  @Test func theVerifiedDefaultPinSurvivesItsOwnValidation() {
    // given
    let reference = PinnedImageReference.verifiedDefault

    // when / then: a typo in the baked-in constant must fail loudly in CI, not at a user's daemon
    #expect(PinnedImageReference.parse(reference.description) == reference)
    #expect(ExecConfig.disabledDefault.imageRegistryAllowlist.contains(reference.registryHost))
  }

  @Test func theDefaultPinObeysTheRegistryAllowlist() {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.execEnabled] = "true"
    env[EnvKey.execCPUs] = "1"
    env[EnvKey.execImageRegistries] = "images.example.com"

    // when / then
    #expect(throws: ConfigError.execImageRegistryNotAllowed("cgr.dev")) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func disabledExecDoesNotFillTheDefaultImage() throws {
    // given
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.exec.image == nil)
  }

  @Test func enabledExecRejectsAnImageOutsideTheRegistryAllowlist() {
    // given
    let rawImage =
      "registry.example.com/team/python@sha256:" + String(repeating: "c", count: 64)
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.execEnabled] = "true"
    env[EnvKey.execImage] = rawImage
    env[EnvKey.execCPUs] = "1"

    // when / then
    #expect(
      throws: ConfigError.execImageRegistryNotAllowed("registry.example.com")
    ) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func enabledExecRejectsCPUAboveTheLiveHostCap() {
    // given
    let rawCPUs = "\(ProcessInfo.processInfo.activeProcessorCount + 1)"
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.execEnabled] = "true"
    env[EnvKey.execImage] =
      "cgr.dev/chainguard/python@sha256:" + String(repeating: "d", count: 64)
    env[EnvKey.execCPUs] = rawCPUs

    // when / then
    #expect(throws: ConfigError.invalidExecCPUs(rawCPUs)) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func execImageWhitespaceFailsClosedAtTheConfigBoundary() {
    // given
    let rawImage =
      " cgr.dev/chainguard/python@sha256:" + String(repeating: "e", count: 64)
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.execImage] = rawImage

    // when / then
    #expect(throws: ConfigError.invalidExecImage(rawImage)) {
      try AppConfig.load(environment: env)
    }
  }

  @Test(arguments: [
    (
      key: AppConfig.EnvKey.execMemoryMiB, value: "255",
      error: ConfigError.invalidExecMemoryMiB("255")
    ),
    (
      key: AppConfig.EnvKey.execMemoryMiB, value: "8193",
      error: ConfigError.invalidExecMemoryMiB("8193")
    ),
    (
      key: AppConfig.EnvKey.execMemoryMiB, value: "large",
      error: ConfigError.invalidExecMemoryMiB("large")
    ),
    (key: AppConfig.EnvKey.execCPUs, value: "0", error: ConfigError.invalidExecCPUs("0")),
    (key: AppConfig.EnvKey.execCPUs, value: "many", error: ConfigError.invalidExecCPUs("many")),
    (key: AppConfig.EnvKey.execTimeout, value: "0", error: ConfigError.invalidExecTimeout("0")),
    (key: AppConfig.EnvKey.execTimeout, value: "301", error: ConfigError.invalidExecTimeout("301")),
    (
      key: AppConfig.EnvKey.execTimeout, value: "later",
      error: ConfigError.invalidExecTimeout("later")
    ),
  ])
  func malformedExecBoundsFailClosed(
    _ fixture: (key: String, value: String, error: ConfigError)
  ) {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[fixture.key] = fixture.value

    // when / then
    #expect(throws: fixture.error) {
      try AppConfig.load(environment: env)
    }
  }

  @Test(arguments: ["", "localhost", "127.0.0.1", "bad host"])
  func invalidOrEmptyRegistryAllowlistFailsClosed(_ rawValue: String) {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.execImageRegistries] = rawValue

    // when / then
    #expect(throws: ConfigError.invalidExecImageRegistry(rawValue)) {
      try AppConfig.load(environment: env)
    }
  }

  @Test(arguments: [AppConfig.EnvKey.execEnabled, AppConfig.EnvKey.execAllowEgress])
  func malformedExecBooleansFailClosed(_ key: String) {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[key] = "sometimes"

    // when / then
    #expect(throws: ConfigError.invalidBool(key: key, value: "sometimes")) {
      try AppConfig.load(environment: env)
    }
  }
}
