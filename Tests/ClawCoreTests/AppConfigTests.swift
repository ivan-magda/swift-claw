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

  @Test func missingTokenIsSecretError() {
    // given
    let env = [
      EnvKey.allowlist: "42",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ]

    // then
    #expect(throws: ConfigError.missingBotToken) {
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

  @Test func nonNumericAllowlistIsConfigError() {
    // given
    let env = [
      EnvKey.botToken: "t",
      EnvKey.allowlist: "42, notanumber",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ]

    // then
    #expect(throws: ConfigError.invalidAllowlist("notanumber")) {
      _ = try AppConfig.load(environment: env)
    }
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

  @Test func missingLLMBaseURLIsConfigError() {
    // given — model present, base URL absent
    let env = [
      EnvKey.botToken: "t",
      EnvKey.stateRoot: NSTemporaryDirectory(),
      EnvKey.llmModel: "gpt-4o",
    ]

    // then
    #expect(throws: ConfigError.missingLLMBaseURL) {
      _ = try AppConfig.load(environment: env)
    }
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
}
