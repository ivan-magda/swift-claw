import ClawCore
import Testing

@testable import ClawLLM

@Suite("Provider roster composition")
struct ProviderRosterFactoryTests {
  @Test("a roster with no fallback route holds the primary alone")
  func primaryOnlyRoster() throws {
    // given
    let primary = chatGPTRoute()

    // when
    let stack = try ProviderStackFactory.makeRoster(
      primaryRoute: primary,
      fallbackRoute: nil,
      settings: settings(route: primary),
      loadStaticBearer: { nil },
      loadFallbackBearer: { nil },
      makeManagedCredentialStore: { ScriptedCredentialStore(.value(nil)) },
      http: ScriptedHTTPExecutor([]),
      buildVersion: "test"
    )

    // then
    #expect(stack.roster.count == 1)
    #expect(stack.roster.hasFallback == false)
    #expect(stack.credentialSources.count == 1)
  }

  @Test("a configured fallback composes a second binding with its own policies")
  func fallbackRosterCarriesOwnPolicies() throws {
    // given
    let primary = chatGPTRoute()
    let fallback = makeCurrentRoute(endpoint: "https://fallback.example/v1")

    // when
    let stack = try ProviderStackFactory.makeRoster(
      primaryRoute: primary,
      fallbackRoute: fallback,
      settings: settings(route: primary),
      loadStaticBearer: { nil },
      loadFallbackBearer: { "fallback-key" },
      makeManagedCredentialStore: { ScriptedCredentialStore(.value(nil)) },
      http: ScriptedHTTPExecutor([]),
      buildVersion: "test"
    )

    // then
    #expect(stack.roster.hasFallback == true)
    #expect(stack.roster.primary.costPolicy == .includedPlan)
    #expect(stack.roster.binding(at: 1).costPolicy == .metered)
    #expect(stack.roster.binding(at: 1).reservationPolicy == .textOnly)
    #expect(stack.credentialSources.count == 2)
  }

  @Test("a fallback route missing its endpoint fails closed at composition")
  func fallbackMissingEndpointFailsClosed() throws {
    // given — the same malformed shape the current-route registry-defect test uses: a static-bearer
    // route carrying a managed egress, impossible for a registered descriptor
    let primary = chatGPTRoute()
    let malformed = currentRouteWithEgress(
      .managed(providerID: .openAICompatible, endpoint: "https://managed.invalid")
    )

    // when / then
    #expect(
      throws: ProviderStackFactory.CompositionError.currentRouteMissingConfiguredEndpoint(
        providerID: .openAICompatible
      )
    ) {
      _ = try ProviderStackFactory.makeRoster(
        primaryRoute: primary,
        fallbackRoute: malformed,
        settings: settings(route: primary),
        loadStaticBearer: { nil },
        loadFallbackBearer: { nil },
        makeManagedCredentialStore: { ScriptedCredentialStore(.value(nil)) },
        http: ScriptedHTTPExecutor([]),
        buildVersion: "test"
      )
    }
  }

  @Test("the fallback bearer never reaches the primary route")
  func bearersAreRouteScoped() throws {
    // given
    let primary = makeCurrentRoute(endpoint: "https://primary.example/v1")
    let fallback = makeCurrentRoute(endpoint: "https://fallback.example/v1")
    var primaryBearerReads = 0
    var fallbackBearerReads = 0

    // when
    _ = try ProviderStackFactory.makeRoster(
      primaryRoute: primary,
      fallbackRoute: fallback,
      settings: settings(route: primary),
      loadStaticBearer: {
        primaryBearerReads += 1
        return "primary-key"
      },
      loadFallbackBearer: {
        fallbackBearerReads += 1
        return "fallback-key"
      },
      makeManagedCredentialStore: { ScriptedCredentialStore(.value(nil)) },
      http: ScriptedHTTPExecutor([]),
      buildVersion: "test"
    )

    // then
    #expect(primaryBearerReads == 1)
    #expect(fallbackBearerReads == 1)
  }
}
