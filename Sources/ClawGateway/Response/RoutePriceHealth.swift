import ClawCore
import Foundation

/// What doctor can say about one route's price: covered by a subscription plan, priced by a known
/// tier, or unpriced, in which case every budget estimate on the route uses the reference rate.
public struct RoutePriceHealth: Sendable, Equatable {
  public enum Pricing: Sendable, Equatable {
    case includedPlan
    case known(KnownPrice)
    case unknown(referenceUSDPerToken: Double)
  }

  public enum Key {
    public static let primary = "spend.primary_price"
    public static let fallback = "spend.fallback_price"
  }

  public let reference: String
  public let pricing: Pricing

  public init(reference: String, pricing: Pricing) {
    self.reference = reference
    self.pricing = pricing
  }

  /// Reads the price `route` is charged at from the resolver the daemon meters with.
  public init(route: ResolvedLLMRoute, resolver: CostResolver) {
    reference = route.configuredReference
    switch route.descriptor.costPolicy {
    case .includedPlan:
      pricing = .includedPlan
    case .metered:
      pricing =
        resolver.knownPrice(for: route.configuredReference).map(Pricing.known)
        ?? .unknown(referenceUSDPerToken: resolver.referenceUSDPerToken)
    }
  }
}

extension HealthRowsBuilder {
  /// One price row per configured route, shared by `doctor --check-config`, full doctor and
  /// `/status`. A metered route with no price fails: its reference-rate estimates can refuse turns
  /// that the real price would allow.
  public static func priceChecks(
    primary: RoutePriceHealth,
    fallback: RoutePriceHealth?
  ) -> [DoctorReport.Check] {
    let primaryCheck = priceCheck(
      primary,
      key: RoutePriceHealth.Key.primary,
      inputVariable: AppConfig.EnvKey.llmInputUSDPerMTok,
      outputVariable: AppConfig.EnvKey.llmOutputUSDPerMTok
    )
    guard let fallback else {
      return [primaryCheck]
    }

    let fallbackCheck = priceCheck(
      fallback,
      key: RoutePriceHealth.Key.fallback,
      inputVariable: AppConfig.EnvKey.llmFallbackInputUSDPerMTok,
      outputVariable: AppConfig.EnvKey.llmFallbackOutputUSDPerMTok
    )
    return [primaryCheck, fallbackCheck]
  }
}

// MARK: - Price Rows

private extension HealthRowsBuilder {
  static func priceCheck(
    _ health: RoutePriceHealth,
    key: String,
    inputVariable: String,
    outputVariable: String
  ) -> DoctorReport.Check {
    let value: String
    let ok: Bool
    switch health.pricing {
    case .includedPlan:
      value = "\(health.reference): included in plan"
      ok = true
    case .known(let known):
      let source = known.source == .configuredPrice ? "configured" : "price file"
      value = """
        \(health.reference): $\(perMTok(known.price.inputUSDPerMTok)) in, \
        $\(perMTok(known.price.outputUSDPerMTok)) out per 1M tokens (\(source))
        """
      ok = true
    case .unknown(let referenceUSDPerToken):
      value = """
        \(health.reference): no price; budget estimates use \
        $\(USD.display(referenceUSDPerToken * 1_000_000)) per 1M tokens. \
        Set \(inputVariable) and \(outputVariable)
        """
      ok = false
    }
    return DoctorReport.Check(key: key, value: value, ok: ok, group: .spend)
  }

  /// A per-1M-token price in cents when that is exact, otherwise with every significant digit, so a
  /// sub-cent price such as 0.0675 is not rounded away.
  static func perMTok(_ usd: Double) -> String {
    let cents = USD.display(usd)
    return Double(cents) == usd ? cents : String(format: "%g", usd)
  }
}
