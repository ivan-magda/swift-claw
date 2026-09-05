import Foundation

// MARK: - LLM Config Parsing

extension AppConfig {
  /// Resolves the route from the model first, so a managed model that names no base URL is not
  /// rejected for lacking one it never uses. The base URL is an autoclosure the registry evaluates
  /// only for the current route, and the wire output-token field is applied only where the route
  /// honors one — the managed ChatGPT route ignores `CLAW_LLM_MAX_TOKENS_FIELD` because it carries no
  /// wire cap. The API key is not read here: it is a secret the composition root hands a credential
  /// source.
  static func parseLLMConfig(from env: [String: String]) throws -> LLMConfig {
    guard
      let model = env[EnvKey.llmModel]?.trimmingCharacters(in: .whitespaces),
      !model.isEmpty
    else {
      throw ConfigError.missingLLMModel
    }

    let resolved = try LLMProviderRegistry.resolve(
      modelReference: model,
      configuredBaseURL: try requiredBaseURL(from: env)
    )
    let route = try routeApplyingWireOutputField(to: resolved, env: env)
    let fallbackRoute = try parseFallbackRoute(from: env)

    let rawMaxTokens = env[EnvKey.llmMaxTokens]?.trimmingCharacters(in: .whitespaces) ?? ""
    let maxOutputTokens: Int
    if rawMaxTokens.isEmpty {
      maxOutputTokens = EnvDefaults.maxOutputTokens
    } else if let parsedMaxTokens = Int(rawMaxTokens), parsedMaxTokens > 0 {
      maxOutputTokens = parsedMaxTokens
    } else {
      throw ConfigError.invalidMaxTokens(rawMaxTokens)
    }

    let structuredOutput = try parseStructuredOutput(
      from: env,
      routes: [route, fallbackRoute].compactMap { configuredRoute in
        configuredRoute
      }
    )

    return LLMConfig(
      route: route,
      maxOutputTokens: maxOutputTokens,
      retryBudget: EnvDefaults.retryBudget,
      requestTimeoutSeconds: EnvDefaults.requestTimeoutSeconds,
      streamingEnabled: try boolValue(
        env[EnvKey.llmStreaming],
        key: EnvKey.llmStreaming,
        default: true
      ),
      structuredOutput: structuredOutput,
      fallbackRoute: fallbackRoute,
      primaryCooldownSeconds: try parsePrimaryCooldown(from: env)
    )
  }
}

// MARK: - LLM Route Validation

private extension AppConfig {
  /// The current route's required base URL, thrown lazily so the registry evaluates it only when the
  /// model resolves to that route. A managed model leaves this unevaluated, which is what lets
  /// `CLAW_LLM_BASE_URL` stay absent for it.
  static func requiredBaseURL(from env: [String: String]) throws -> String {
    guard
      let baseURL = env[EnvKey.llmBaseURL]?.trimmingCharacters(in: .whitespaces),
      !baseURL.isEmpty
    else {
      throw ConfigError.missingLLMBaseURL
    }
    return baseURL
  }

  /// Resolves the fallback route, or `nil` when none is configured. The fallback's base URL is a
  /// distinct variable: reusing the primary's would silently point a fallback at the endpoint that
  /// just failed, and would let a missing primary endpoint pass validation.
  static func parseFallbackRoute(from env: [String: String]) throws -> ResolvedLLMRoute? {
    guard
      let model = env[EnvKey.llmFallbackModel]?.trimmingCharacters(in: .whitespaces),
      !model.isEmpty
    else {
      return nil
    }

    let resolved = try LLMProviderRegistry.resolve(
      modelReference: model,
      configuredBaseURL: try requiredFallbackBaseURL(from: env)
    )

    return try routeApplyingWireOutputField(
      to: resolved,
      env: env,
      fieldKey: EnvKey.llmFallbackMaxTokensField
    )
  }

  /// The fallback route's required base URL, thrown lazily for the same reason `requiredBaseURL` is:
  /// a managed fallback never evaluates this closure, so it stays exempt from the variable.
  static func requiredFallbackBaseURL(from env: [String: String]) throws -> String {
    guard
      let baseURL = env[EnvKey.llmFallbackBaseURL]?.trimmingCharacters(in: .whitespaces),
      !baseURL.isEmpty
    else {
      throw ConfigError.missingLLMFallbackBaseURL
    }
    return baseURL
  }

  /// The primary's cooldown window: how long a route-switch trip keeps the daemon off the primary
  /// before it is retried. Absent/blank falls back to the 900-second default, else must be positive.
  static func parsePrimaryCooldown(from env: [String: String]) throws -> Int {
    try ConfigParse.boundedInt(
      env[EnvKey.primaryCooldownSeconds],
      default: EnvDefaults.primaryCooldownSeconds,
      range: 1...Int.max,
      onInvalid: ConfigError.invalidPrimaryCooldown
    )
  }

  /// Rebuilds a route's wire output-token field from its own field-override variable, but only when
  /// the resolved descriptor carries a configured field. A route that omits the wire cap honors no
  /// such variable, so it is neither read nor validated there — parsing it would resurrect a value
  /// the route ignores and reject a value it never consults. `fieldKey` lets the primary and the
  /// fallback share this one implementation instead of each growing a near-copy.
  static func routeApplyingWireOutputField(
    to route: ResolvedLLMRoute,
    env: [String: String],
    fieldKey: String = EnvKey.llmMaxTokensField
  ) throws -> ResolvedLLMRoute {
    guard case .configured = route.descriptor.capabilities.outputTokenField else {
      return route
    }

    let rawField = env[fieldKey]?.trimmingCharacters(in: .whitespaces) ?? ""
    let maxTokensField: MaxTokensField
    if rawField.isEmpty {
      maxTokensField = EnvDefaults.maxTokensField
    } else if let parsedField = MaxTokensField(rawValue: rawField) {
      maxTokensField = parsedField
    } else {
      throw ConfigError.invalidMaxTokensField(rawField)
    }

    let capabilities = route.descriptor.capabilities
    let rebuilt = LLMProviderDescriptor(
      providerID: route.descriptor.providerID,
      qualifiedPrefix: route.descriptor.qualifiedPrefix,
      egress: route.descriptor.egress,
      credentialMode: route.descriptor.credentialMode,
      capabilities: LLMProviderCapabilities(
        supportsStructuredOutput: capabilities.supportsStructuredOutput,
        outputTokenField: .configured(maxTokensField)
      )
    )

    return ResolvedLLMRoute(
      descriptor: rebuilt,
      configuredReference: route.configuredReference,
      wireModel: route.wireModel
    )
  }

  /// Parses `CLAW_LLM_STRUCTURED_OUTPUT` and enforces every configured route's capability: a mode the
  /// fallback cannot serve is a latent failure the moment the fallback carries a turn, so a route with
  /// no relied-upon structured-output contract accepts only `off` — any other value fails closed with
  /// the offending route named rather than being silently sent to a wire that cannot honor it.
  static func parseStructuredOutput(
    from env: [String: String],
    routes: [ResolvedLLMRoute]
  ) throws -> StructuredOutputMode {
    let rawStructuredOutput =
      env[EnvKey.llmStructuredOutput]?.trimmingCharacters(in: .whitespaces) ?? ""
    let structuredOutput: StructuredOutputMode

    if rawStructuredOutput.isEmpty {
      structuredOutput = EnvDefaults.structuredOutput
    } else if let parsedMode = StructuredOutputMode(rawValue: rawStructuredOutput) {
      structuredOutput = parsedMode
    } else {
      throw ConfigError.invalidStructuredOutput(rawStructuredOutput)
    }

    let unsupportedRoute = routes.first { candidate in
      !candidate.descriptor.capabilities.supportsStructuredOutput
    }
    if structuredOutput != .off, let unsupportedRoute {
      throw ConfigError.structuredOutputUnsupportedOnRoute(
        providerID: unsupportedRoute.descriptor.providerID,
        mode: structuredOutput
      )
    }

    return structuredOutput
  }
}
