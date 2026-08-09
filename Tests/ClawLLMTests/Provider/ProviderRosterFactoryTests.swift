import ClawCore
import ClawTestSupport
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

  // MARK: - Quota-retry flag wiring

  @Test("a configured fallback disables quota retries on the primary but not on the fallback")
  func quotaRetriesDisabledOnPrimaryOnlyWhenFallbackIsConfigured() async throws {
    // given — two ChatGPT routes, so the same retry engine answers a 429 on both stacks; a budget of
    // 2 is wide enough that only the flag, not an exhausted budget, can explain a single attempt
    let primary = chatGPTRoute()
    let fallback = chatGPTRoute()
    let http = ScriptedHTTPExecutor([
      quotaWallStep(),
      quotaWallStep(),
      quotaWallStep(),
    ])
    let stack = try ProviderStackFactory.makeRoster(
      primaryRoute: primary,
      fallbackRoute: fallback,
      settings: settings(route: primary, retryBudget: 2),
      loadStaticBearer: { nil },
      loadFallbackBearer: { nil },
      makeManagedCredentialStore: { ScriptedCredentialStore(.value(storedCredential())) },
      http: http,
      buildVersion: "test"
    )

    // when — the primary's first 429 fails terminally rather than spending its second budgeted
    // attempt
    _ = try? await stack.roster.primary.provider.complete(request: sampleRequest)
    let afterPrimary = await http.recorded.count

    // and — the fallback's first 429 still retries, spending both budgeted attempts
    _ = try? await stack.roster.binding(at: 1).provider.complete(request: sampleRequest)
    let afterFallback = await http.recorded.count

    // then
    #expect(afterPrimary == 1)
    #expect(afterFallback - afterPrimary == 2)
  }

  @Test("no fallback route leaves the primary retrying a 429 as it always has")
  func quotaRetriesStayEnabledOnThePrimaryWithoutAFallback() async throws {
    // given — the same 429 script, with no fallback route configured
    let primary = chatGPTRoute()
    let http = ScriptedHTTPExecutor([quotaWallStep(), quotaWallStep()])
    let stack = try ProviderStackFactory.makeRoster(
      primaryRoute: primary,
      fallbackRoute: nil,
      settings: settings(route: primary, retryBudget: 2),
      loadStaticBearer: { nil },
      loadFallbackBearer: { nil },
      makeManagedCredentialStore: { ScriptedCredentialStore(.value(storedCredential())) },
      http: http,
      buildVersion: "test"
    )

    // when
    _ = try? await stack.roster.primary.provider.complete(request: sampleRequest)

    // then — the retry still spends both budgeted attempts
    #expect(await http.recorded.count == 2)
  }
}

// MARK: - Builders

private extension ProviderRosterFactoryTests {
  /// A clean 429 with no `Retry-After` wait, so a retried attempt does not sleep in real time.
  func quotaWallStep() -> ScriptedHTTPExecutor.Step {
    .stream(Support.head(429, retryAfter: 0), Fixtures.errorBody("slow down"))
  }
}

private typealias Support = ChatGPTProviderTestSupport
private typealias Fixtures = Support.Fixtures
