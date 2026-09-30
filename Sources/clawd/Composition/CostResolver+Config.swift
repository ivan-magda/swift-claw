import ClawCore
import ClawLLM

extension CostResolver {
  /// The resolver the daemon meters with: the bundled price snapshot, the owner's configured route
  /// prices, and the reference rate. Doctor builds its price rows from this same factory, so it
  /// cannot report a price the daemon does not charge.
  static func configured(by config: AppConfig) -> CostResolver {
    CostResolver(
      priceTable: PriceFileLoader.load(),
      referenceUSDPerToken: config.budget.referenceUSDPerToken,
      configuredPrices: config.llm.configuredPrices
    )
  }
}
