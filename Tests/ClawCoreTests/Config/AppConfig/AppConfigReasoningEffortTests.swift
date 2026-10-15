import Foundation
import Testing

@testable import ClawCore

@Suite
struct AppConfigReasoningEffortTests {
  private typealias EnvKey = AppConfig.EnvKey

  /// The words are the wire spelling an owner types, so each is written out here rather than read
  /// back from the enum that parses it.
  @Test(arguments: ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"])
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

  @Test
  func anUnknownWordFailsConfigurationNamingTheAllowedWords() {
    // given
    let env = chatGPTEnv([EnvKey.llmReasoningEffort: "hihg"])

    // then
    #expect(
      throws: ConfigError.invalidReasoningEffort(
        value: "hihg",
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
