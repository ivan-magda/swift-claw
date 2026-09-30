import Foundation
import Testing

@testable import ClawCore

@Suite
struct AppConfigLLMPriceTests {
  private typealias EnvKey = AppConfig.EnvKey

  private static let model = "openai/gpt-6-luna"

  /// A metered primary on an OpenAI-compatible endpoint, the route a configured price applies to.
  private func meteredEnv(_ overrides: [String: String] = [:]) -> [String: String] {
    [
      EnvKey.stateRoot: NSTemporaryDirectory(),
      EnvKey.llmBaseURL: "https://openrouter.example/api/v1",
      EnvKey.llmModel: Self.model,
    ].merging(overrides) { _, new in
      new
    }
  }

  @Test
  func eachRouteReadsItsOwnPricePair() throws {
    // given — both routes metered, each with its own pair
    let env = meteredEnv([
      EnvKey.llmInputUSDPerMTok: "0.10",
      EnvKey.llmOutputUSDPerMTok: "0.50",
      EnvKey.llmFallbackModel: "google/gemma-4-26b-a4b-it:free",
      EnvKey.llmFallbackBaseURL: "https://openrouter.example/api/v1",
      EnvKey.llmFallbackInputUSDPerMTok: "0",
      EnvKey.llmFallbackOutputUSDPerMTok: "0",
    ])

    // when
    let config = try AppConfig.load(environment: env)

    // then — keyed by each route's model reference, the key the cost resolver looks prices up by
    #expect(
      config.llm.configuredPrices == [
        Self.model: ModelPrice(inputUSDPerMTok: 0.10, outputUSDPerMTok: 0.50),
        "google/gemma-4-26b-a4b-it:free": ModelPrice(inputUSDPerMTok: 0, outputUSDPerMTok: 0),
      ]
    )
  }

  @Test(arguments: [
    (set: EnvKey.llmInputUSDPerMTok, missing: EnvKey.llmOutputUSDPerMTok),
    (set: EnvKey.llmOutputUSDPerMTok, missing: EnvKey.llmInputUSDPerMTok),
  ])
  func aLonePriceVariableFailsClosedNamingItsTwin(set: String, missing: String) {
    // given — half a pair; pricing the other side at zero would under-gate every call
    let env = meteredEnv([set: "0.10"])

    // then
    #expect(throws: ConfigError.incompleteLLMPrice(missing: missing)) {
      try AppConfig.load(environment: env)
    }
  }

  @Test(arguments: ["abc", "-0.10", "inf"])
  func aPriceThatIsNotAFiniteNonNegativeNumberFailsClosed(raw: String) {
    // given
    let env = meteredEnv([
      EnvKey.llmInputUSDPerMTok: raw,
      EnvKey.llmOutputUSDPerMTok: "0.50",
    ])

    // then
    #expect(throws: ConfigError.invalidLLMPrice(key: EnvKey.llmInputUSDPerMTok, value: raw)) {
      try AppConfig.load(environment: env)
    }
  }

  @Test
  func aPlanBilledRouteLeavesThePriceVariablesUnread() throws {
    // given — a subscription primary with a malformed price left in the environment
    let env = [
      EnvKey.stateRoot: NSTemporaryDirectory(),
      EnvKey.llmModel: "openai-chatgpt/gpt-6-sol",
      EnvKey.llmInputUSDPerMTok: "abc",
    ]

    // when
    let config = try AppConfig.load(environment: env)

    // then — the plan pays for every call, so no price is read or rejected there
    #expect(config.llm.configuredPrices.isEmpty)
  }

  @Test
  func twoRoutesNamingOneModelMustAgreeOnItsPrice() {
    // given — the fallback names the primary's model at a different price
    let env = meteredEnv([
      EnvKey.llmInputUSDPerMTok: "0.10",
      EnvKey.llmOutputUSDPerMTok: "0.50",
      EnvKey.llmFallbackModel: Self.model,
      EnvKey.llmFallbackBaseURL: "https://other.example/v1",
      EnvKey.llmFallbackInputUSDPerMTok: "0.20",
      EnvKey.llmFallbackOutputUSDPerMTok: "0.50",
    ])

    // then — usage is keyed by model reference, so one of the two prices would silently lose
    #expect(throws: ConfigError.conflictingLLMPrices(reference: Self.model)) {
      try AppConfig.load(environment: env)
    }
  }
}
