import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite
struct RoutePriceHealthTests {
  private static let referenceUSDPerToken = 0.000_015
  private static let price = ModelPrice(inputUSDPerMTok: 0.1, outputUSDPerMTok: 0.5)

  private static let meteredRoute = ResolvedLLMRoute(
    descriptor: .openAICompatible(endpoint: "https://openrouter.example/api/v1"),
    configuredReference: "openai/gpt-6-luna",
    wireModel: "openai/gpt-6-luna"
  )
  private static let planRoute = ResolvedLLMRoute(
    descriptor: .openAIChatGPT,
    configuredReference: "openai-chatgpt/gpt-6-sol",
    wireModel: "gpt-6-sol"
  )

  struct PricingCase: Sendable, CustomTestStringConvertible {
    let name: String
    let route: ResolvedLLMRoute
    let table: [String: ModelPrice]
    let expected: RoutePriceHealth.Pricing

    var testDescription: String {
      name
    }
  }

  static let pricingCases = [
    PricingCase(
      name: "a plan-billed route needs no price",
      route: planRoute,
      table: [:],
      expected: .includedPlan
    ),
    PricingCase(
      name: "a metered route the table prices",
      route: meteredRoute,
      table: ["openrouter/openai/gpt-6-luna": price],
      expected: .known(KnownPrice(price: price, source: .priceFile))
    ),
    PricingCase(
      name: "a metered route nothing prices",
      route: meteredRoute,
      table: [:],
      expected: .unknown(referenceUSDPerToken: referenceUSDPerToken)
    ),
  ]

  @Test(arguments: pricingCases)
  func reportsThePriceTheDaemonChargesTheRouteAt(_ testCase: PricingCase) {
    // given
    let resolver = CostResolver(
      priceTable: PriceTable(prices: testCase.table),
      referenceUSDPerToken: Self.referenceUSDPerToken
    )

    // when
    let health = RoutePriceHealth(route: testCase.route, resolver: resolver)

    // then
    #expect(health.pricing == testCase.expected)
  }

  @Test(arguments: [
    (RoutePriceHealth.Pricing.includedPlan, true),
    (.known(KnownPrice(price: price, source: .configuredPrice)), true),
    (.unknown(referenceUSDPerToken: referenceUSDPerToken), false),
  ])
  func onlyAMeteredRouteWithNoPriceFails(pricing: RoutePriceHealth.Pricing, ok: Bool) throws {
    // given
    let primary = RoutePriceHealth(reference: "openai/gpt-6-luna", pricing: pricing)

    // when
    let checks = HealthRowsBuilder.priceChecks(primary: primary, fallback: nil)

    // then
    let row = try #require(
      checks.first {
        $0.key == RoutePriceHealth.Key.primary
      }
    )
    #expect(row.ok == ok)
  }

  @Test
  func anUnpricedRowNamesTheModelAndTheVariablesThatPriceIt() throws {
    // given
    let primary = RoutePriceHealth(
      reference: "openai/gpt-6-luna",
      pricing: .unknown(referenceUSDPerToken: Self.referenceUSDPerToken)
    )

    // when
    let row = try #require(HealthRowsBuilder.priceChecks(primary: primary, fallback: nil).first)

    // then — the row is the fix, so it has to name what to set
    #expect(row.value.contains("openai/gpt-6-luna"))
    #expect(row.value.contains(AppConfig.EnvKey.llmInputUSDPerMTok))
    #expect(row.value.contains(AppConfig.EnvKey.llmOutputUSDPerMTok))
  }

  @Test
  func aConfiguredFallbackGetsItsOwnRowNamingItsOwnVariables() throws {
    // given — a priced primary and an unpriced fallback
    let primary = RoutePriceHealth(
      reference: "openai/gpt-6-luna",
      pricing: .known(KnownPrice(price: Self.price, source: .priceFile))
    )
    let fallback = RoutePriceHealth(
      reference: "vendor/fallback-model",
      pricing: .unknown(referenceUSDPerToken: Self.referenceUSDPerToken)
    )

    // when
    let checks = HealthRowsBuilder.priceChecks(primary: primary, fallback: fallback)

    // then
    let row = try #require(
      checks.first {
        $0.key == RoutePriceHealth.Key.fallback
      }
    )
    #expect(row.ok == false)
    #expect(row.value.contains(AppConfig.EnvKey.llmFallbackInputUSDPerMTok))
    #expect(row.value.contains(AppConfig.EnvKey.llmFallbackOutputUSDPerMTok))
  }
}
