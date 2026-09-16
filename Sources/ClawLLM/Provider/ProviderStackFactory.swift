import ClawAuth
import ClawCore
import Foundation
import Logging

// MARK: - Provider stack

/// One resolved route composed into the binding turn consumers drive and the live credential source
/// the shutdown sequence must commit.
///
/// The concrete provider and credential types are gone by this boundary. A caller holds `any
/// LLMProvider` and `any LLMCredentialSource`, so no scheduled-run or agent signature below carries a
/// `ChatGPT` or `OpenAICompatible` type, and adding a managed provider registers a descriptor and
/// composes an adapter here rather than branching downstream.
public struct ProviderStack: Sendable {
  public let binding: LLMRouteBinding
  public let credentialSource: any LLMCredentialSource

  public init(binding: LLMRouteBinding, credentialSource: any LLMCredentialSource) {
    self.binding = binding
    self.credentialSource = credentialSource
  }
}

/// A composed roster plus the credential sources the shutdown sequence must commit.
///
/// The sources are held apart from the roster because a turn drives routes while only composition
/// closes them.
public struct RosterStack: Sendable {
  public let roster: ProviderRoster
  public let credentialSources: [any LLMCredentialSource]
}

// MARK: - Factory

/// The one place a resolved route becomes a concrete provider stack.
///
/// It lives in `ClawLLM` rather than the executable so a test executes the production selection
/// logic — which route builds which adapter, which credential seam it opens, and which policies it
/// stamps — instead of re-deriving it.
public enum ProviderStackFactory {
  /// A route reached the factory in a shape its credential mode structurally forbids.
  ///
  /// Every case is impossible for a correctly registered descriptor, so it names a registry defect,
  /// not a configuration error: the factory fails closed at boot rather than composing a broken
  /// wire.
  public enum CompositionError: Error, Equatable {
    /// A current route (`.noneOrStaticBearer`) carried a non-`.configuredEndpoint` egress, so no
    /// endpoint was chosen.
    ///
    /// Composing would point the wire at nothing; this surfaces instead.
    case currentRouteMissingConfiguredEndpoint(providerID: LLMProviderID)
    /// A current route (`.noneOrStaticBearer`) carried a non-`.configured` output-token field, so
    /// no wire key was chosen.
    ///
    /// Composing would silently pick an unchosen default; this surfaces instead.
    case currentRouteMissingOutputField(providerID: LLMProviderID)
  }

  // The pinned route-directed signature carries six inputs by design — the resolved route, the neutral
  // settings, the two lazy per-route credential seams, the dedicated executor, and the build version.
  // swiftlint:disable function_parameter_count
  /// Composes the provider and credential lifetime selected by a resolved route.
  ///
  /// - Parameters:
  ///   - route: The resolved wire, credential, and accounting identities.
  ///   - settings: Provider settings shared by the configured routes.
  ///   - loadStaticBearer: Reads this route's static bearer once; unused by a managed route.
  ///   - makeManagedCredentialStore: Creates the encrypted store once for a managed route.
  ///     A missing record permits logged-out startup; malformed or insecure credentials fail boot.
  ///   - http: The dedicated provider transport with redirects disabled.
  ///   - buildVersion: The application version sanitized into the subscription User-Agent;
  ///     unused by the OpenAI-compatible route.
  ///   - treatsQuotaAsTerminal: Whether a subscription 429 should fail immediately to a fallback
  ///     instead of using the retry budget; unused by the OpenAI-compatible route.
  /// - Returns: The route binding and the credential source that shutdown must close.
  /// - Throws: `CompositionError` for an inconsistent route descriptor, or a credential-store
  ///   failure when managed credentials cannot be loaded safely.
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
  /// Composes every configured route and its credential lifetime at boot.
  ///
  /// - Parameters:
  ///   - primaryRoute: The route used when no fallback or cooldown applies.
  ///   - fallbackRoute: The optional route used when the primary is unavailable.
  ///   - settings: Provider settings shared by both routes.
  ///   - loadStaticBearer: Reads the primary's static bearer when that route needs it.
  ///   - loadFallbackBearer: Reads only the fallback's static bearer, when configured and needed.
  ///   - makeManagedCredentialStore: Creates the store for a route using managed credentials.
  ///   - http: The dedicated provider transport with redirects disabled.
  ///   - buildVersion: The application version used by subscription adapters.
  /// - Returns: The ordered route roster and every credential source shutdown must close.
  /// - Throws: A route-composition or credential-store failure from either configured route;
  ///   a broken fallback fails startup rather than being deferred until failover.
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
        roster: ProviderRoster(primary: primaryStack.binding),
        credentialSources: [primaryStack.credentialSource]
      )
    }
    // The fallback is the last route, so its own quota wall is worth retrying: there is nowhere
    // further to fail onto.
    let fallbackStack = try make(
      route: fallbackRoute,
      settings: settings,
      loadStaticBearer: loadFallbackBearer,
      makeManagedCredentialStore: makeManagedCredentialStore,
      http: http,
      buildVersion: buildVersion
    )
    return RosterStack(
      roster: ProviderRoster(primary: primaryStack.binding, fallback: fallbackStack.binding),
      credentialSources: [primaryStack.credentialSource, fallbackStack.credentialSource]
    )
  }  // swiftlint:enable function_parameter_count
}

// MARK: - Current route

private extension ProviderStackFactory {
  /// Composes the OpenAI-compatible adapter with its resolved endpoint and static bearer.
  ///
  /// An absent bearer permits a keyless local server. The binding uses metered cost and text-only
  /// reservation policies; the endpoint arrives resolved and is not canonicalized again.
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
    let binding = LLMRouteBinding(
      provider: provider,
      wireModel: route.wireModel,
      configuredReference: route.configuredReference,
      costPolicy: .metered,
      reservationPolicy: .textOnly
    )
    return ProviderStack(binding: binding, credentialSource: credentialSource)
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
      throw CompositionError.currentRouteMissingOutputField(providerID: route.descriptor.providerID)
    }
    return field
  }
}

// MARK: - ChatGPT route

private extension ProviderStackFactory {
  /// The managed ChatGPT Responses stack.
  ///
  /// The credential is loaded and validated once before the actor is built, so loading is never a
  /// second implicit refresh flight: a missing record boots logged out (the source authenticates
  /// before any inference and the daemon still delivers login guidance), and a malformed envelope
  /// throws for the caller to map to the secret-load exit code.
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
      oauth: ChatGPTOAuthClient(http: http) {
        Date()
      },
      clock: ContinuousClock()
    ) {
      Date()
    }
    let provider = ChatGPTResponsesProvider(
      http: http,
      credentials: credentialSource,
      credentialProfileID: initial?.profileID,
      buildVersion: buildVersion,
      retryBudget: settings.retryBudget,
      requestTimeoutSeconds: settings.requestTimeoutSeconds,
      clock: ContinuousClock(),
      jitter: Self.jitter,
      epochID: {
        UUID()
      },
      treatsQuotaAsTerminal: treatsQuotaAsTerminal
    )
    let binding = LLMRouteBinding(
      provider: provider,
      wireModel: route.wireModel,
      configuredReference: route.configuredReference,
      costPolicy: .includedPlan,
      reservationPolicy: .chatGPTReplayState
    )
    return ProviderStack(binding: binding, credentialSource: credentialSource)
  }
}

// MARK: - Shared wiring

private extension ProviderStackFactory {
  /// The bootstrapped production logger, so a composed provider's diagnostics reach the redacting
  /// backend rather than a silent no-op.
  ///
  /// It is not a test seam: the factory is the production path.
  static var llmLogger: Logger {
    Logger(label: "clawd.llm")
  }

  /// Uniform jittered backoff for both adapters: a full-jitter draw over the capped exponential
  /// window, matching what the daemon wired inline before the factory owned composition.
  @Sendable
  static func jitter(_ cap: Duration) -> Duration {
    Duration.seconds(Double.random(in: 0...(cap / .seconds(1))))
  }
}
