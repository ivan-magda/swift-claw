import ClawAuth
import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawLLM

// MARK: - Doubles

/// A credential store whose one behavior a test scripts: a present record, an absent one (logged
/// out), or a typed store failure. It records whether it was opened at all, so the current route can
/// be proven never to touch it.
private final class ScriptedCredentialStore: LLMCredentialStore, @unchecked Sendable {
  enum Behavior: Sendable {
    case value(StoredOAuthCredential?)
    case failure(LLMCredentialStoreError)
  }

  let behavior: Behavior
  private(set) var loadCount = 0

  init(_ behavior: Behavior) {
    self.behavior = behavior
  }

  func load(providerID: LLMProviderID) throws(LLMCredentialStoreError) -> StoredOAuthCredential? {
    loadCount += 1
    switch behavior {
    case .value(let credential):
      return credential
    case .failure(let error):
      throw error
    }
  }

  func save(
    _ credential: StoredOAuthCredential,
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) {}

  func delete(providerID: LLMProviderID) throws(LLMCredentialStoreError) {}
}

/// Flips when its closure is invoked, so a test can assert a route did — or did not — read the seam.
private final class InvocationFlag: @unchecked Sendable {
  private(set) var invoked = false

  func mark() { invoked = true }
}

@Suite struct ProviderStackFactoryTests {
  private var chatGPTRoute: ResolvedLLMRoute {
    ResolvedLLMRoute(
      descriptor: .openAIChatGPT,
      configuredReference: "openai-chatgpt/gpt-5.4",
      wireModel: "gpt-5.4"
    )
  }

  private func settings(route: ResolvedLLMRoute) -> LLMConfig {
    LLMConfig(route: route, maxOutputTokens: 256, retryBudget: 3, requestTimeoutSeconds: 30)
  }

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

  // MARK: - ChatGPT route

  @Test func chatGPTRouteBuildsTheIncludedPlanResponsesStackAndReadsNoStaticBearer() throws {
    // given — the managed route, a static-bearer closure that fails if the route ever reads it
    let bearerRead = InvocationFlag()
    let store = ScriptedCredentialStore(.value(storedCredential()))

    // when
    let stack = try ProviderStackFactory.make(
      route: chatGPTRoute,
      settings: settings(route: chatGPTRoute),
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
      route: chatGPTRoute,
      settings: settings(route: chatGPTRoute),
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
        route: chatGPTRoute,
        settings: settings(route: chatGPTRoute),
        loadStaticBearer: { nil },
        makeManagedCredentialStore: { store },
        http: ScriptedHTTPExecutor([]),
        buildVersion: "0.0.0-test"
      )
    }
  }
}
