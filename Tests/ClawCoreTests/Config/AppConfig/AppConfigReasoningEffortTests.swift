import Foundation
import Testing

@testable import ClawCore

@Suite
struct AppConfigReasoningEffortTests {
  private typealias EnvKey = AppConfig.EnvKey

  /// The words are the wire spelling an owner types, so each is written out here rather than read
  /// back from the enum that parses it.
  @Test(arguments: ["none", "low", "medium", "high", "xhigh", "max"])
  func eachDocumentedLevelConfiguresTheChatGPTPrimary(word: String) throws {
    // given
    let env = chatGPTEnv([EnvKey.llmReasoningEffort: word])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    let effort = config.llm.route.descriptor.capabilities.reasoningEffort
    #expect(effort.configuredLevel?.rawValue == word)
  }

  @Test
  func aBlankValueLeavesTheLevelToTheProvider() throws {
    // given
    let env = chatGPTEnv([EnvKey.llmReasoningEffort: "  "])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.llm.route.descriptor.capabilities.reasoningEffort == .providerDefault)
  }

  /// A typo, and the two catalog words the Codex wire refuses: `ultra` is listed for some models
  /// but is a client mode, and `minimal` is rejected outright. Either would fail every message.
  @Test(arguments: ["hihg", "ultra", "minimal"])
  func aWordOutsideTheWireLevelsFailsConfigurationNamingTheAllowedWords(word: String) {
    // given
    let env = chatGPTEnv([EnvKey.llmReasoningEffort: word])

    // when / then
    #expect(
      throws: ConfigError.invalidReasoningEffort(
        value: word,
        allowed: LLMReasoningEffort.allCases.map(\.rawValue)
      )
    ) {
      try AppConfig.load(environment: env)
    }
  }

  /// Switching to the compatible route stays a change to the model alone: a level left behind in
  /// the environment, even a misspelled one, is neither read nor rejected there.
  @Test
  func theCompatibleRouteIgnoresTheSettingEvenWhenInvalid() throws {
    // given
    let env = [
      EnvKey.stateRoot: NSTemporaryDirectory(),
      EnvKey.llmBaseURL: "http://localhost:1234/v1",
      EnvKey.llmModel: "gpt-4o",
      EnvKey.llmReasoningEffort: "hihg",
    ]

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.llm.route.descriptor.capabilities.reasoningEffort == .unsupported)
  }

  /// The fallback exists to answer when the primary cannot, so it never inherits a level its model
  /// might refuse.
  @Test
  func aChatGPTFallbackKeepsTheProviderDefault() throws {
    // given
    let env = chatGPTEnv([
      EnvKey.llmReasoningEffort: "high",
      EnvKey.llmFallbackModel: "openai-chatgpt/gpt-5.4-mini",
    ])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    try #require(config.llm.route.descriptor.capabilities.reasoningEffort == .configured(.high))
    let fallback = try #require(config.llm.fallbackRoute)
    #expect(fallback.descriptor.capabilities.reasoningEffort == .providerDefault)
  }
}
