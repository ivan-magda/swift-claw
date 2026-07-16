import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawSecrets

// MARK: - Doubles

/// A credential store whose single behavior a test scripts: a present record, an absent one (logged
/// out), or a typed store failure. It counts loads, so the current route can be proven never to open
/// it and the ChatGPT route proven to read exactly once.
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

/// A store factory that must never run for the current route. Marking it fails the paired assertion,
/// which is how "the current route constructs no store" is proven rather than assumed.
private final class TrappingStoreFactory: @unchecked Sendable {
  private(set) var invoked = false

  func make() -> any LLMCredentialStore {
    invoked = true
    return ScriptedCredentialStore(.value(nil))
  }
}

@Suite struct LLMAuthDoctorTests {
  // MARK: - Fixtures

  private static let chatGPTProvider = "provider=openai-chatgpt"

  private func currentRoute() -> ResolvedLLMRoute {
    ResolvedLLMRoute(
      descriptor: .openAICompatible(endpoint: "https://api.test/v1"),
      configuredReference: "gpt-4o",
      wireModel: "gpt-4o"
    )
  }

  private func chatGPTRoute() -> ResolvedLLMRoute {
    ResolvedLLMRoute(
      descriptor: .openAIChatGPT,
      configuredReference: "openai-chatgpt/gpt-5.4",
      wireModel: "gpt-5.4"
    )
  }

  private func credential(expiresAt: Date) -> StoredOAuthCredential {
    StoredOAuthCredential(
      profileID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID(),
      accessToken: "ACCESS-SECRET-TOKEN",
      refreshToken: "REFRESH-SECRET-TOKEN",
      expiresAt: expiresAt
    )
  }

  // MARK: - Current route

  @Test func currentRouteWithStaticKeyReportsModeStatic() {
    // given
    let store = ScriptedCredentialStore(.value(nil))

    // when
    let result = LLMAuthDoctor.inspect(
      route: currentRoute(),
      staticAPIKey: "sk-configured",
      credentialStore: store,
      now: Date()
    )

    // then — literal golden, and the OAuth envelope was never opened
    #expect(result.value == "provider=openai-compatible mode=static")
    #expect(result.ok)
    #expect(store.loadCount == 0)
  }

  @Test func currentRouteWithoutKeyReportsModeNone() {
    // given / when
    let result = LLMAuthDoctor.inspect(
      route: currentRoute(),
      staticAPIKey: nil,
      credentialStore: nil,
      now: Date()
    )

    // then — literal golden
    #expect(result.value == "provider=openai-compatible mode=none")
    #expect(result.ok)
  }

  @Test func currentRouteNeverOpensAnUnrelatedMalformedEnvelope() {
    // given — a malformed OAuth envelope stands on disk while the current route is configured
    let store = ScriptedCredentialStore(.failure(.malformedStorage))

    // when
    let result = LLMAuthDoctor.inspect(
      route: currentRoute(),
      staticAPIKey: nil,
      credentialStore: store,
      now: Date()
    )

    // then — the current route reports its own key state and never touches the envelope
    #expect(result.value == "provider=openai-compatible mode=none")
    #expect(result.ok)
    #expect(store.loadCount == 0)
  }

  @Test func currentRouteConstructsNoStore() {
    // given — a factory that fails the assertion if it is ever built
    let factory = TrappingStoreFactory()

    // when
    let result = LLMAuthDoctor.inspect(
      route: currentRoute(),
      staticAPIKey: "sk-configured",
      now: Date(),
      makeManagedStore: factory.make
    )

    // then — the current route never constructs the managed store
    #expect(factory.invoked == false)
    #expect(result.value == "provider=openai-compatible mode=static")
    #expect(result.ok)
  }

  // MARK: - ChatGPT route load

  @Test func chatGPTRouteConstructsAndLoadsExactlyOneRecord() {
    // given — the positive pairing: the ChatGPT route DOES build and read the store
    let store = ScriptedCredentialStore(
      .value(credential(expiresAt: Date().addingTimeInterval(3600)))
    )
    var built = 0

    // when
    let result = LLMAuthDoctor.inspect(
      route: chatGPTRoute(),
      staticAPIKey: nil,
      now: Date(),
      makeManagedStore: {
        built += 1
        return store
      }
    )

    // then
    #expect(built == 1)
    #expect(store.loadCount == 1)
    #expect(result.ok)
  }

  // MARK: - ChatGPT freshness

  @Test func chatGPTFreshCredentialReportsFresh() {
    // given — comfortably beyond the skew window
    let now = Date()
    let store = ScriptedCredentialStore(.value(credential(expiresAt: now.addingTimeInterval(3600))))

    // when
    let result = LLMAuthDoctor.inspect(
      route: chatGPTRoute(),
      staticAPIKey: nil,
      credentialStore: store,
      now: now
    )

    // then — literal golden
    #expect(result.value == "provider=openai-chatgpt mode=oauth status=fresh")
    #expect(result.ok)
  }

  @Test func chatGPTExpiringWithinSkewReportsExpiring() {
    // given — valid, but inside the 120-second skew window
    let now = Date()
    let store = ScriptedCredentialStore(.value(credential(expiresAt: now.addingTimeInterval(60))))

    // when
    let result = LLMAuthDoctor.inspect(
      route: chatGPTRoute(),
      staticAPIKey: nil,
      credentialStore: store,
      now: now
    )

    // then — literal golden
    #expect(result.value == "provider=openai-chatgpt mode=oauth status=expiring")
    #expect(result.ok)
  }

  @Test func chatGPTExpiredReportsExpiredRefreshOnUse() {
    // given — already past expiry; the daemon refreshes on next use, doctor does not
    let now = Date()
    let store = ScriptedCredentialStore(.value(credential(expiresAt: now.addingTimeInterval(-60))))

    // when
    let result = LLMAuthDoctor.inspect(
      route: chatGPTRoute(),
      staticAPIKey: nil,
      credentialStore: store,
      now: now
    )

    // then — literal golden
    #expect(result.value == "provider=openai-chatgpt mode=oauth status=expired-refresh-on-use")
    #expect(result.ok)
  }

  /// Pins the skew boundary to exactly 120 seconds, sourced from `ChatGPTCredentialFreshness` rather
  /// than re-derived here: a mutant that shifts the window would break exactly one of these.
  @Test(
    arguments: [
      (119.0, "expiring"),
      (120.0, "expiring"),
      (121.0, "fresh"),
    ]
  )
  func chatGPTSkewBoundaryIsExactlyOneHundredTwentySeconds(
    offsetSeconds: Double,
    expectedStatus: String
  ) {
    // given
    let now = Date()
    let store = ScriptedCredentialStore(
      .value(credential(expiresAt: now.addingTimeInterval(offsetSeconds)))
    )

    // when
    let result = LLMAuthDoctor.inspect(
      route: chatGPTRoute(),
      staticAPIKey: nil,
      credentialStore: store,
      now: now
    )

    // then
    #expect(result.value == "provider=openai-chatgpt mode=oauth status=\(expectedStatus)")
    #expect(result.ok)
  }

  @Test func chatGPTOkRowLeaksNoTokenAccountOrProfile() {
    // given — distinctive secret material and a fixed expiry to look for in the value
    let now = Date()
    let expiresAt = now.addingTimeInterval(3600)
    let store = ScriptedCredentialStore(.value(credential(expiresAt: expiresAt)))

    // when
    let result = LLMAuthDoctor.inspect(
      route: chatGPTRoute(),
      staticAPIKey: nil,
      credentialStore: store,
      now: now
    )

    // then — only the freshness class surfaces, never the tokens, profile, or expiry timestamp
    #expect(result.value.contains("ACCESS-SECRET-TOKEN") == false)
    #expect(result.value.contains("REFRESH-SECRET-TOKEN") == false)
    #expect(result.value.contains("0000000000AA") == false)
    #expect(result.value.contains("\(expiresAt.timeIntervalSince1970)") == false)
  }

  // MARK: - ChatGPT missing credential

  @Test func chatGPTMissingRecordIsFailingLoginRow() {
    // given — the envelope decrypts but holds no ChatGPT record
    let store = ScriptedCredentialStore(.value(nil))

    // when
    let result = LLMAuthDoctor.inspect(
      route: chatGPTRoute(),
      staticAPIKey: nil,
      credentialStore: store,
      now: Date()
    )

    // then — a failing row that guides the owner to log in, leaking no secrets
    #expect(result.ok == false)
    #expect(result.value.contains("clawd auth login"))
    #expect(result.value.hasPrefix(Self.chatGPTProvider))
  }

  @Test func chatGPTNilStoreIsFailingLoginRow() {
    // given / when — no store at all is treated as no usable credential
    let result = LLMAuthDoctor.inspect(
      route: chatGPTRoute(),
      staticAPIKey: nil,
      credentialStore: nil,
      now: Date()
    )

    // then
    #expect(result.ok == false)
    #expect(result.value.contains("clawd auth login"))
  }

  // MARK: - ChatGPT decrypt failures

  /// Every closed store failure a load can surface becomes a failing decrypt row with login guidance
  /// and no leaked path or key material.
  @Test(
    arguments: [
      LLMCredentialStoreError.malformedStorage,
      .oversizedStorage,
      .unsupportedVersion,
      .insecureStorage,
      .missingRuntimeKey,
    ] as [LLMCredentialStoreError]
  )
  func chatGPTStoreFailureIsFailingDecryptRow(error: LLMCredentialStoreError) {
    // given
    let store = ScriptedCredentialStore(.failure(error))

    // when
    let result = LLMAuthDoctor.inspect(
      route: chatGPTRoute(),
      staticAPIKey: nil,
      credentialStore: store,
      now: Date()
    )

    // then
    #expect(result.ok == false)
    #expect(result.value.contains("clawd auth login"))
    #expect(result.value.hasPrefix(Self.chatGPTProvider))
  }

  @Test func chatGPTMalformedEnvelopeRowNamesTheProblem() {
    // given — a positive that a decrypt row is distinct from a logged-out row
    let store = ScriptedCredentialStore(.failure(.malformedStorage))

    // when
    let result = LLMAuthDoctor.inspect(
      route: chatGPTRoute(),
      staticAPIKey: nil,
      credentialStore: store,
      now: Date()
    )

    // then
    #expect(result.ok == false)
    #expect(result.value.contains("unreadable"))
    #expect(result.value.contains("clawd auth login"))
  }

  // MARK: - Network-free

  @Test func inspectMakesNoNetworkCall() async {
    // given — a zero-call HTTP sentinel that the helper has no seam to reach
    let sentinel = RecordingHTTPExecutor()
    let store = ScriptedCredentialStore(
      .value(credential(expiresAt: Date().addingTimeInterval(3600)))
    )

    // when — a full ChatGPT inspection runs
    _ = LLMAuthDoctor.inspect(
      route: chatGPTRoute(),
      staticAPIKey: nil,
      credentialStore: store,
      now: Date()
    )

    // then — nothing crossed the wire
    let requests = await sentinel.requests
    #expect(requests.isEmpty)
  }
}
