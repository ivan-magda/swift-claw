import Foundation

// MARK: - LLM Route Prices

extension AppConfig {
  /// The owner-set prices for the configured routes, for models the vendored price table lacks.
  ///
  /// Usage and cost are keyed by model reference, so two routes that name one model must not name
  /// two different prices for it.
  static func parseRoutePrices(
    route: ResolvedLLMRoute,
    fallbackRoute: ResolvedLLMRoute?,
    env: [String: String]
  ) throws -> (route: ModelPrice?, fallback: ModelPrice?) {
    let primaryPrice = try price(for: route, env: env, keys: .primary)
    let fallbackPrice = try fallbackRoute.flatMap { fallback in
      try price(for: fallback, env: env, keys: .fallback)
    }

    if let fallbackRoute, fallbackRoute.configuredReference == route.configuredReference,
       let primaryPrice, let fallbackPrice, primaryPrice != fallbackPrice
    {
      throw ConfigError.conflictingLLMPrices(reference: route.configuredReference)
    }

    return (primaryPrice, fallbackPrice)
  }
}

// MARK: - Route Price Parsing

private extension AppConfig {
  /// One route's pair of price variables.
  struct PriceKeys {
    static let primary = PriceKeys(
      input: EnvKey.llmInputUSDPerMTok,
      output: EnvKey.llmOutputUSDPerMTok
    )
    static let fallback = PriceKeys(
      input: EnvKey.llmFallbackInputUSDPerMTok,
      output: EnvKey.llmFallbackOutputUSDPerMTok
    )

    let input: String
    let output: String
  }

  /// A metered route's price, or `nil` when neither of its variables is set. A route billed by its
  /// plan honors no price, so its variables are neither read nor validated there. One variable
  /// without the other fails closed: pricing the missing side at zero would under-gate every call.
  static func price(
    for route: ResolvedLLMRoute,
    env: [String: String],
    keys: PriceKeys
  ) throws -> ModelPrice? {
    guard route.descriptor.costPolicy == .metered else {
      return nil
    }

    let input = try usdPerMTok(env[keys.input], key: keys.input)
    let output = try usdPerMTok(env[keys.output], key: keys.output)
    switch (input, output) {
    case (nil, nil):
      return nil
    case (let input?, let output?):
      return ModelPrice(inputUSDPerMTok: input, outputUSDPerMTok: output)
    case (nil, .some):
      throw ConfigError.incompleteLLMPrice(missing: keys.input)
    case (.some, nil):
      throw ConfigError.incompleteLLMPrice(missing: keys.output)
    }
  }

  static func usdPerMTok(_ raw: String?, key: String) throws -> Double? {
    try ConfigParse.nonNegativeDoubleOrNil(raw) { value in
      ConfigError.invalidLLMPrice(key: key, value: value)
    }
  }
}
