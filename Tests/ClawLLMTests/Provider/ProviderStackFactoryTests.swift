import ClawAuth
import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawLLM

// MARK: - Doubles

/// Flips when its closure is invoked, so a test can assert a route did — or did not — read the seam.
private final class InvocationFlag: @unchecked Sendable {
  private(set) var invoked = false

  func mark() { invoked = true }
}

@Suite struct ProviderStackFactoryTests {
  private func storedCredential() -> StoredOAuthCredential {
    StoredOAuthCredential(
      profileID: UUID(),
      accessToken: "access-token",
      refreshToken: "refresh-token",
      expiresAt: Date().addingTimeInterval(3600)
    )
  }

  // MARK: - Current route

  @Test func currentRouteBuildsTheMeteredStaticStackAndOpensNoOAuthEnvelope() throws {
    // given — the current route, a managed-store factory that fails if the route ever opens it
    let route = makeCurrentRoute(endpoint: "https://api.test/v1", model: "gpt-4o")
    let managedOpened = InvocationFlag()

    // when
    let stack = try ProviderStackFactory.make(
      route: route,
      settings: settings(route: route),
      loadStaticBearer: { "sk-test" },
      makeManagedCredentialStore: {
        managedOpened.mark()
        return ScriptedCredentialStore(.value(nil))
      },
      http: ScriptedHTTPExecutor([]),
      buildVersion: "0.0.0-test"
    )

    // then — the OpenAI-compatible adapter, metered and text-only, with the current route never
    // touching the OAuth envelope
    #expect(stack.provider is OpenAICompatibleProvider)
    #expect(stack.costPolicy == .metered)
    #expect(stack.reservationPolicy == .textOnly)
    #expect(stack.wireModel == "gpt-4o")
    #expect(stack.configuredReference == "gpt-4o")
    #expect(managedOpened.invoked == false)
  }

  @Test func currentRouteSendsToTheResolvedChatCompletionsURL() async throws {
    // given — the composed current-route provider and a scripted 200
    let route = makeCurrentRoute(endpoint: "https://api.test/v1", model: "gpt-4o")
    let http = ScriptedHTTPExecutor([okStep()])
    let stack = try ProviderStackFactory.make(
      route: route,
      settings: settings(route: route),
      loadStaticBearer: { "sk-test" },
      makeManagedCredentialStore: { ScriptedCredentialStore(.value(nil)) },
      http: http,
      buildVersion: "0.0.0-test"
    )

    // when
    _ = try await stack.provider.complete(request: sampleRequest)

    // then — the resolved endpoint reached the wire as the Chat Completions URL
    let recorded = await http.recorded
    #expect(recorded.map(\.url) == ["https://api.test/v1/chat/completions"])
  }

  // MARK: - Registry defects fail closed

  @Test func aCurrentRouteWithoutAConfiguredEndpointFailsClosedRatherThanComposing() {
    // given — a static-bearer route carrying a managed egress: impossible for a registered descriptor,
    // so a registry defect, not configuration
    let route = currentRouteWithEgress(
      .managed(providerID: .openAICompatible, endpoint: "https://managed.invalid")
    )

    // then — the factory throws the typed composition error rather than composing a wire URL that
    // points at nothing
    #expect(
      throws: ProviderStackFactory.CompositionError.currentRouteMissingConfiguredEndpoint(
        providerID: .openAICompatible
      )
    ) {
      _ = try makeStack(route: route)
    }
  }

  @Test func aCurrentRouteWithoutAConfiguredOutputFieldFailsClosedRatherThanComposing() {
    // given — a static-bearer route whose output-token field is omitted: again a registry defect
    let route = currentRouteWithOutputField(.omitted)

    // then — the factory throws rather than degrading to an unchosen wire key
    #expect(
      throws: ProviderStackFactory.CompositionError.currentRouteMissingOutputField(
        providerID: .openAICompatible
      )
    ) {
      _ = try makeStack(route: route)
    }
  }

  // MARK: - ChatGPT route

  @Test func chatGPTRouteBuildsTheIncludedPlanResponsesStackAndReadsNoStaticBearer() throws {
    // given — the managed route, a static-bearer closure that fails if the route ever reads it
    let bearerRead = InvocationFlag()
    let store = ScriptedCredentialStore(.value(storedCredential()))

    // when
    let stack = try ProviderStackFactory.make(
      route: chatGPTRoute(),
      settings: settings(route: chatGPTRoute()),
      loadStaticBearer: {
        bearerRead.mark()
        return "unused"
      },
      makeManagedCredentialStore: { store },
      http: ScriptedHTTPExecutor([]),
      buildVersion: "0.0.0-test"
    )

    // then — the Responses adapter, included-plan with the replay reservation, the OAuth envelope
    // loaded exactly once, and the static bearer never read
    #expect(stack.provider is ChatGPTResponsesProvider<ContinuousClock>)
    #expect(stack.costPolicy == .includedPlan)
    #expect(stack.reservationPolicy == .chatGPTReplayState)
    #expect(stack.wireModel == "gpt-5.4")
    #expect(stack.configuredReference == "openai-chatgpt/gpt-5.4")
    #expect(store.loadCount == 1)
    #expect(bearerRead.invoked == false)
  }

  @Test func chatGPTRouteWithNoRecordBootsLoggedOut() throws {
    // given — an absent record: a valid logged-out state, not a failure
    let store = ScriptedCredentialStore(.value(nil))

    // when / then — the stack builds without throwing, and the envelope was still opened once
    let stack = try ProviderStackFactory.make(
      route: chatGPTRoute(),
      settings: settings(route: chatGPTRoute()),
      loadStaticBearer: { nil },
      makeManagedCredentialStore: { store },
      http: ScriptedHTTPExecutor([]),
      buildVersion: "0.0.0-test"
    )
    #expect(stack.provider is ChatGPTResponsesProvider<ContinuousClock>)
    #expect(store.loadCount == 1)
  }

  @Test func chatGPTRouteWithMalformedEnvelopeThrowsTheStoreError() {
    // given — a malformed envelope: fatal, not logged out
    let store = ScriptedCredentialStore(.failure(.malformedStorage))

    // then — the closed store taxonomy propagates for the caller to map to the secret-load exit code
    #expect(throws: LLMCredentialStoreError.malformedStorage) {
      _ = try ProviderStackFactory.make(
        route: chatGPTRoute(),
        settings: settings(route: chatGPTRoute()),
        loadStaticBearer: { nil },
        makeManagedCredentialStore: { store },
        http: ScriptedHTTPExecutor([]),
        buildVersion: "0.0.0-test"
      )
    }
  }

  @Test func chatGPTRouteSendsToTheFixedResponsesURLWithTheStoreSeededBearer() async throws {
    // given — the composed managed provider over a store-seeded credential and a scripted success. The
    // seeded token is unexpired, so the source spends it directly rather than opening a refresh flight.
    let credential = storedCredential()
    let http = ScriptedHTTPExecutor([
      .stream(ChatGPTProviderTestSupport.okHead, ChatGPTProviderTestSupport.Fixtures.basicSuccess())
    ])
    let stack = try ProviderStackFactory.make(
      route: chatGPTRoute(),
      settings: settings(route: chatGPTRoute()),
      loadStaticBearer: { nil },
      makeManagedCredentialStore: { ScriptedCredentialStore(.value(credential)) },
      http: http,
      buildVersion: "0.0.0-test"
    )

    // when
    _ = try await stack.provider.complete(request: sampleRequest)

    // then — the factory wired the fixed Codex Responses URL and the store-seeded bearer reached it,
    // the symmetric twin of the current-route wire assertion
    let recorded = try #require(await http.recorded.first)
    #expect(recorded.url == ChatGPTProviderMetadata.responsesURL)
    #expect(recorded.headers["Authorization"] == "Bearer \(credential.accessToken)")
  }
}

// MARK: - Builders

private extension ProviderStackFactoryTests {
  /// Composes a stack over stubbed seams, so a route-shape test asserts only the factory's decision.
  func makeStack(route: ResolvedLLMRoute) throws -> ProviderStack {
    try ProviderStackFactory.make(
      route: route,
      settings: settings(route: route),
      loadStaticBearer: { "sk-test" },
      makeManagedCredentialStore: { ScriptedCredentialStore(.value(nil)) },
      http: ScriptedHTTPExecutor([]),
      buildVersion: "0.0.0-test"
    )
  }

  /// A static-bearer route carrying an arbitrary output-token field, to reach the current-route
  /// composition path with a shape a registered descriptor never produces — a registry defect, not
  /// configuration.
  func currentRouteWithOutputField(_ field: LLMWireOutputTokenField) -> ResolvedLLMRoute {
    ResolvedLLMRoute(
      descriptor: LLMProviderDescriptor(
        providerID: .openAICompatible,
        qualifiedPrefix: nil,
        egress: .configuredEndpoint("https://api.test/v1"),
        credentialMode: .noneOrStaticBearer,
        capabilities: LLMProviderCapabilities(
          supportsStructuredOutput: true,
          outputTokenField: field
        )
      ),
      configuredReference: "gpt-4o",
      wireModel: "gpt-4o"
    )
  }
}
