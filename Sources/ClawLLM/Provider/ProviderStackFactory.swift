import ClawAuth
import ClawCore
import Foundation
import Logging

// MARK: - Provider stack

/// One resolved route composed into everything downstream needs and nothing it does not: the erased
/// provider `AgentRuntime` and the schedule parser drive, the two model identities they split wire
/// traffic from accounting with, the two policies that decide billing and input reservation, and the
/// live credential source the shutdown sequence must commit.
///
/// The concrete provider and credential types are gone by this boundary. A caller holds `any
/// LLMProvider` and `any LLMCredentialSource`, so no scheduled-run or agent signature below carries a
/// `ChatGPT` or `OpenAICompatible` type, and adding a managed provider registers a descriptor and
/// composes an adapter here rather than branching downstream.
public struct ProviderStack: Sendable {
  public let provider: any LLMProvider
  public let credentialSource: any LLMCredentialSource
  public let wireModel: String
  public let configuredReference: String
  public let costPolicy: LLMCostPolicy
  public let reservationPolicy: LLMInputReservationPolicy

  public init(
    provider: any LLMProvider,
    credentialSource: any LLMCredentialSource,
    wireModel: String,
    configuredReference: String,
    costPolicy: LLMCostPolicy,
    reservationPolicy: LLMInputReservationPolicy
  ) {
    self.provider = provider
    self.credentialSource = credentialSource
    self.wireModel = wireModel
    self.configuredReference = configuredReference
    self.costPolicy = costPolicy
    self.reservationPolicy = reservationPolicy
  }
}

public extension ProviderStack {
  /// The turn-facing slice of this stack. Drops the credential source, which belongs to
  /// composition's shutdown sequence and never to a turn.
  var binding: LLMRouteBinding {
    LLMRouteBinding(
      provider: provider,
      wireModel: wireModel,
      configuredReference: configuredReference,
      costPolicy: costPolicy,
      reservationPolicy: reservationPolicy
    )
  }
}

/// A composed roster plus the credential sources the shutdown sequence must commit. The sources are
/// held apart from the roster because a turn drives routes while only composition closes them.
public struct RosterStack: Sendable {
  public let roster: ProviderRoster
  public let credentialSources: [any LLMCredentialSource]
}

// MARK: - Factory

/// The one place a resolved route becomes a concrete provider stack. It lives in `ClawLLM` rather than
/// the executable so a test executes the production selection logic — which route builds which adapter,
/// which credential seam it opens, and which policies it stamps — instead of re-deriving it.
public enum ProviderStackFactory {
  /// A route reached the factory in a shape its credential mode structurally forbids. Every case is
  /// impossible for a correctly registered descriptor, so it names a registry defect, not a
  /// configuration error: the factory fails closed at boot rather than composing a broken wire.
  public enum CompositionError: Error, Equatable {
    /// A current route (`.noneOrStaticBearer`) carried a non-`.configuredEndpoint` egress, so no
    /// endpoint was chosen. Composing would point the wire at nothing; this surfaces instead.
    case currentRouteMissingConfiguredEndpoint(providerID: LLMProviderID)
    /// A current route (`.noneOrStaticBearer`) carried a non-`.configured` output-token field, so no
    /// wire key was chosen. Composing would silently pick an unchosen default; this surfaces instead.
    case currentRouteMissingOutputField(providerID: LLMProviderID)
  }

  // The pinned route-directed signature carries six inputs by design — the resolved route, the neutral
  // settings, the two lazy per-route credential seams, the dedicated executor, and the build version.
  // swiftlint:disable function_parameter_count
  /// Composes the stack the route selects. The two secret seams are lazy and each belongs to exactly
  /// one route: the static bearer closure is read only for the current route and the managed store is
  /// built only for the ChatGPT route, so a route never opens the other's credential path.
  ///
  /// - Parameter loadStaticBearer: the current route's static bearer, read once. Never invoked on the
  ///   managed route.
  /// - Parameter makeManagedCredentialStore: builds the encrypted credential store, invoked once and
  ///   only for the managed route. Its `load` throws the closed store taxonomy: a missing record is a
  ///   valid logged-out boot, a malformed or insecure envelope propagates for the caller to map to the
  ///   secret-load exit code.
  /// - Parameter buildVersion: `ClawdVersion.current`, sanitized by the ChatGPT adapter into its
  ///   User-Agent. Unused by the current route.
  /// - Parameter treatsQuotaAsTerminal: whether a 429 on this route should fail immediately rather
  ///   than spend the retry budget — set for the primary only when a fallback route exists to take
  ///   over. Unused by the current route, which carries no subscription quota to wall against.
  public static func make(
    route: ResolvedLLMRoute,
    settings: LLMConfig,
    loadStaticBearer: () -> String?,
    makeManagedCredentialStore: () -> any LLMCredentialStore,
    http: any HTTPExecuting & HTTPStreaming,
    buildVersion: String,
    treatsQuotaAsTerminal: Bool = false
  ) throws -> ProviderStack {
    switch route.descriptor.credentialMode {
    case .noneOrStaticBearer:
      return try currentStack(
        route: route,
        settings: settings,
        bearer: loadStaticBearer(),
        http: http
      )
    case .managedOAuth:
      return try managedStack(
        route: route,
        settings: settings,
        store: makeManagedCredentialStore(),
        http: http,
        buildVersion: buildVersion,
        treatsQuotaAsTerminal: treatsQuotaAsTerminal
      )
    }
  }
  // swiftlint:enable function_parameter_count

  // swiftlint:disable function_parameter_count
  /// Composes every configured route at boot. A fallback that cannot be built is a startup failure,
  /// never a surprise discovered when the primary's quota runs out.
  ///
  /// - Parameter loadFallbackBearer: the fallback route's static bearer. Read only when a fallback
  ///   route is configured, and never for the primary.
  public static func makeRoster(
    primaryRoute: ResolvedLLMRoute,
    fallbackRoute: ResolvedLLMRoute?,
    settings: LLMConfig,
    loadStaticBearer: () -> String?,
    loadFallbackBearer: () -> String?,
    makeManagedCredentialStore: () -> any LLMCredentialStore,
    http: any HTTPExecuting & HTTPStreaming,
    buildVersion: String
  ) throws -> RosterStack {
    // A fallback route existing is the whole condition: only then is retrying a quota wall on the
    // primary pure waste, because only then is there somewhere else to finish the turn.
    let primaryStack = try make(
      route: primaryRoute,
      settings: settings,
      loadStaticBearer: loadStaticBearer,
      makeManagedCredentialStore: makeManagedCredentialStore,
      http: http,
      buildVersion: buildVersion,
      treatsQuotaAsTerminal: fallbackRoute != nil
    )
    guard let fallbackRoute else {
      return RosterStack(
        roster: ProviderRoster(bindings: [primaryStack.binding]),
        credentialSources: [primaryStack.credentialSource]
      )
    }
    // The fallback is the last route in the chain, so its own quota wall is worth retrying: there is
    // nowhere further to fail onto.
    let fallbackStack = try make(
      route: fallbackRoute,
      settings: settings,
      loadStaticBearer: loadFallbackBearer,
      makeManagedCredentialStore: makeManagedCredentialStore,
      http: http,
      buildVersion: buildVersion
    )
    return RosterStack(
      roster: ProviderRoster(bindings: [primaryStack.binding, fallbackStack.binding]),
      credentialSources: [primaryStack.credentialSource, fallbackStack.credentialSource]
    )
  }
  // swiftlint:enable function_parameter_count
}

// MARK: - Current route

private extension ProviderStackFactory {
  /// The configured OpenAI-compatible Chat Completions stack: a static bearer (or none, for a keyless
  /// local server), the wire adapter pointed at the route's resolved endpoint, and metered text-only
  /// policies. The endpoint arrives already resolved from the route; this never re-canonicalizes it.
  static func currentStack(
    route: ResolvedLLMRoute,
    settings: LLMConfig,
    bearer: String?,
    http: any HTTPExecuting & HTTPStreaming
  ) throws -> ProviderStack {
    let credentialSource = StaticLLMCredentialSource(bearer: bearer)
    let provider = OpenAICompatibleProvider(
      config: settings,
      endpoint: try configuredEndpoint(of: route),
      maxTokensField: try wireOutputField(of: route),
      credentials: credentialSource,
      http: http,
      clock: ContinuousClock(),
      jitter: Self.jitter,
      logger: Self.llmLogger
    )
    return ProviderStack(
      provider: provider,
      credentialSource: credentialSource,
      wireModel: route.wireModel,
      configuredReference: route.configuredReference,
      costPolicy: .metered,
      reservationPolicy: .textOnly
    )
  }

  static func configuredEndpoint(of route: ResolvedLLMRoute) throws -> String {
    guard case .configuredEndpoint(let endpoint) = route.descriptor.egress else {
      // A none-or-static-bearer route resolves to a configured endpoint by construction; a managed
      // egress reaching here is a registry defect, not configuration. Fail closed at boot rather
      // than compose a wire URL pointed at nothing.
      throw CompositionError.currentRouteMissingConfiguredEndpoint(
        providerID: route.descriptor.providerID
      )
    }
    return endpoint
  }

  static func wireOutputField(of route: ResolvedLLMRoute) throws -> MaxTokensField {
    guard case .configured(let field) = route.descriptor.capabilities.outputTokenField else {
      // A none-or-static-bearer route always carries a configured field by construction; its absence
      // here is a registry defect. Fail closed at boot rather than degrade to an unchosen wire key.
      throw CompositionError.currentRouteMissingOutputField(
        providerID: route.descriptor.providerID
      )
    }
    return field
  }
}

// MARK: - ChatGPT route

private extension ProviderStackFactory {
  /// The managed ChatGPT Responses stack. The credential is loaded and validated once before the
  /// actor is built, so loading is never a second implicit refresh flight: a missing record boots
  /// logged out (the source authenticates before any inference and the daemon still delivers login
  /// guidance), and a malformed envelope throws for the caller to map to the secret-load exit code.
  static func managedStack(
    route: ResolvedLLMRoute,
    settings: LLMConfig,
    store: any LLMCredentialStore,
    http: any HTTPExecuting & HTTPStreaming,
    buildVersion: String,
    treatsQuotaAsTerminal: Bool = false
  ) throws -> ProviderStack {
    let initial = try store.load(providerID: ChatGPTProviderMetadata.providerID)

    let credentialSource = ChatGPTCredentialSource(
      initialCredential: initial,
      store: store,
      oauth: ChatGPTOAuthClient(http: http, wallDate: { Date() }),
      clock: ContinuousClock(),
      wallDate: { Date() }
    )
    let provider = ChatGPTResponsesProvider(
      http: http,
      credentials: credentialSource,
      credentialProfileID: initial?.profileID,
      buildVersion: buildVersion,
      retryBudget: settings.retryBudget,
      requestTimeoutSeconds: settings.requestTimeoutSeconds,
      clock: ContinuousClock(),
      jitter: Self.jitter,
      epochID: { UUID() },
      treatsQuotaAsTerminal: treatsQuotaAsTerminal
    )
    return ProviderStack(
      provider: provider,
      credentialSource: credentialSource,
      wireModel: route.wireModel,
      configuredReference: route.configuredReference,
      costPolicy: .includedPlan,
      reservationPolicy: .chatGPTReplayState
    )
  }
}

// MARK: - Shared wiring

private extension ProviderStackFactory {
  /// The bootstrapped production logger, so a composed provider's diagnostics reach the redacting
  /// backend rather than a silent no-op. It is not a test seam: the factory is the production path.
  static var llmLogger: Logger { Logger(label: "clawd.llm") }

  /// Uniform jittered backoff for both adapters: a full-jitter draw over the capped exponential
  /// window, matching what the daemon wired inline before the factory owned composition.
  @Sendable static func jitter(_ cap: Duration) -> Duration {
    Duration.seconds(Double.random(in: 0...(cap / .seconds(1))))
  }
}
