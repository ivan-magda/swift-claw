import Foundation
import Testing

@testable import ClawCore

@Suite struct AppConfigTests {
  private typealias EnvKey = AppConfig.EnvKey

  /// Adds the LLM keys every successful `load` now requires, unless the base already sets them.
  private func envWithLLM(_ base: [String: String]) -> [String: String] {
    base.merging([
      EnvKey.llmBaseURL: "http://localhost:1234/v1",
      EnvKey.llmModel: "gpt-4o",
      EnvKey.llmApiKey: "sk-test",
    ]) { existing, _ in existing }
  }

  @Test func loadsValidConfig() throws {
    // given
    let env = envWithLLM([
      EnvKey.botToken: "123:abc",
      EnvKey.allowlist: "42, 99",
      EnvKey.stateRoot: NSTemporaryDirectory(),
      EnvKey.pollTimeout: "20",
    ])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.botToken == "123:abc")
    #expect(config.allowlist == [42, 99])
    #expect(config.pollTimeoutSeconds == 20)
    #expect(config.llm.model == "gpt-4o")
  }

  @Test(arguments: [
    (
      "missingBotToken",
      envWithLLM: true,
      overrides: [:],
      omitKeys: [EnvKey.botToken],
      expectedError: ConfigError.missingBotToken
    ),
    (
      "missingLLMBaseURL",
      envWithLLM: false,
      overrides: [EnvKey.llmModel: "gpt-4o"],
      omitKeys: [],
      expectedError: ConfigError.missingLLMBaseURL
    ),
    (
      "invalidAllowlist",
      envWithLLM: true,
      overrides: [EnvKey.allowlist: "42, notanumber"],
      omitKeys: [],
      expectedError: ConfigError.invalidAllowlist("notanumber")
    ),
  ]) func missingOrInvalidConfigFieldThrows(
    description: String,
    envWithLLM: Bool,
    overrides: [String: String],
    omitKeys: [String],
    expectedError: ConfigError
  ) {
    // given
    var env = [
      EnvKey.botToken: "t",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ]
    if envWithLLM {
      env[EnvKey.llmBaseURL] = "http://localhost:1234/v1"
      env[EnvKey.llmModel] = "gpt-4o"
      env[EnvKey.llmApiKey] = "sk-test"
    }
    env.merge(overrides) { _, new in new }
    for key in omitKeys {
      env.removeValue(forKey: key)
    }

    // then
    #expect(throws: expectedError) {
      _ = try AppConfig.load(environment: env)
    }
  }

  @Test func emptyAllowlistIsAllowed() throws {
    // given
    let env = envWithLLM([
      EnvKey.botToken: "t",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.allowlist.isEmpty)
  }

  @Test func defaultsPollTimeoutTo30() throws {
    // given
    let env = envWithLLM([
      EnvKey.botToken: "t",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.pollTimeoutSeconds == 30)
  }

  @Test func blankStateRootFallsBackToHomeDefaultNotCwd() throws {
    // given — copying .env.example verbatim leaves CLAW_STATE_ROOT blank
    let blankEnv = envWithLLM([EnvKey.botToken: "t", EnvKey.stateRoot: "   "])
    let omittedEnv = envWithLLM([EnvKey.botToken: "t"])

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
    let env = envWithLLM([
      EnvKey.botToken: "t",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.llm.maxTokensField == .maxCompletionTokens)
    #expect(config.llm.maxOutputTokens == 4096)
  }

  @Test func maxTokensFieldOverrideParses() throws {
    // given
    var env = envWithLLM([
      EnvKey.botToken: "t",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ])
    env[EnvKey.llmMaxTokensField] = "max_tokens"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.llm.maxTokensField == .maxTokens)
  }

  @Test func perDayUSDOverrideParses() throws {
    // given
    var env = envWithLLM([
      EnvKey.botToken: "t",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ])
    env[EnvKey.perDayUSD] = "5"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.budget.perDayUSD == 5)
  }

  @Test func budgetDefaultsMirrorRunBudgetAndLLM() throws {
    // given
    let env = envWithLLM([
      EnvKey.botToken: "t",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.budget.perDayUSD == RunBudget.default.perDayUSD)
    #expect(config.budget.maxOutputTokens == config.llm.maxOutputTokens)
    #expect(config.budget.dayTokenCeilingOverride == nil)
  }

  @Test func invalidBudgetValueThrows() {
    // given
    var env = envWithLLM([
      EnvKey.botToken: "t",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ])
    env[EnvKey.perRunUSD] = "-1"

    // when / then
    #expect(throws: ConfigError.invalidBudget("-1")) {
      try AppConfig.load(environment: env)
    }
  }
}
