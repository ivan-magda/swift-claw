import ClawCore
import ClawGateway
import Foundation
import Testing

@testable import clawd

@Suite
struct DoctorHealthPriceTests {
  @Test
  func doctorReportsTheConfiguredPriceTheDaemonMetersWith() throws {
    // given — a metered model the bundled table does not list, priced in configuration
    let config = try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: NSTemporaryDirectory(),
      AcceptanceEnv.baseURL: "https://openrouter.example/api/v1",
      AppConfig.EnvKey.llmModel: "vendor/unlisted-model",
      AppConfig.EnvKey.llmInputUSDPerMTok: "0.10",
      AppConfig.EnvKey.llmOutputUSDPerMTok: "0.50",
    ])

    // when
    let prices = DoctorHealth.routePrices(config: config)

    // then — doctor reads the owner's price, so the route passes instead of failing as unpriced
    #expect(
      prices.primary.pricing
        == .known(
          KnownPrice(
            price: ModelPrice(inputUSDPerMTok: 0.10, outputUSDPerMTok: 0.50),
            source: .configuredPrice
          )
        )
    )
  }
}
