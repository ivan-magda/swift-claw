import ClawCore
import ClawSecrets
import ClawTestSupport
import Foundation
import Synchronization

@testable import ClawAuth

/// The auth acceptance world: one login's collaborators over a real, disposable state root, wired to
/// the *real* device-authorization, OAuth-exchange, and catalog clients driven over **scripted HTTP**
/// and a **manual clock** — the higher-fidelity bar than the workflow suites, which inject scripted
/// seams. Real crypto (`RuntimeSecretPreparer`, `EncryptedLLMCredentialStore`) and a real instance
/// lock stay in the loop; only the network boundary and the pacing clock are scripted. Reuses the
/// module-scoped doubles from `AuthWorld` (`RealRuntimeSecrets`, `ObservedCredentialStore`,
/// `RecordingTerminal`, `AuthEffectLog`) so the two suites cannot drift.
struct AuthAcceptanceWorld: Sendable {
  let root: URL
  let log = AuthEffectLog()

  /// Every scripted wire answer, keyed by URL. Defaults to the happy path: usercode, an immediate
  /// grant on the first poll, a token exchange, and a two-model catalog.
  var responses: [String: HTTPResult]
  var environment: [String: String]
  var configuredModel: String?
  var lockFailure: AuthMutationLockFailure?
  var mutationLock: (any AuthMutationLocking)?
  var terminal = RecordingTerminal(isInteractive: false)
  var profileID = AcceptanceAuthFixture.freshProfileID

  init(root: URL) {
    self.root = root
    environment = [EnvSecretStore.EnvKey.botToken: AcceptanceAuthFixture.botToken]
    responses = AcceptanceAuthFixture.happyResponses
  }

  var paths: SecretStatePaths { SecretStatePaths(stateRoot: root) }

  var storedCredential: StoredOAuthCredential? {
    try? EncryptedLLMCredentialStore(stateRoot: root).load(providerID: .openAIChatGPT)
  }

  /// The scripted transport shared by every real client the workflow drives, so a test can read the
  /// exact wire URLs that were reached — the proof that device egress happened (or did not).
  func makeHTTP() -> RecordingHTTPExecutor {
    RecordingHTTPExecutor(responses: responses)
  }

  private var makeCredentialStore: @Sendable () -> any LLMCredentialStore {
    let stateRoot = root
    let effects = log
    return {
      effects.record(.credentialStoreOpened)
      return ObservedCredentialStore(
        inner: EncryptedLLMCredentialStore(stateRoot: stateRoot),
        log: effects
      )
    }
  }

  func loginWorkflow(http: RecordingHTTPExecutor) -> AuthLoginWorkflow {
    let identity = profileID
    let wallDate: @Sendable () -> Date = { AcceptanceAuthFixture.wallNow }
    return AuthLoginWorkflow(
      bootstrap: AuthBootstrap(stateRoot: root, configuredModel: configuredModel),
      runtimeSecrets: RealRuntimeSecrets(stateRoot: root, environment: environment, log: log),
      mutationLock: mutationLock ?? ScriptedLock(failure: lockFailure, log: log),
      makeCredentialStore: makeCredentialStore,
      makeDeviceAuthorization: {
        ChatGPTDeviceAuthorization(
          client: ChatGPTOAuthClient(http: http, wallDate: wallDate),
          // A manual clock that never actually sleeps: the happy path grants on the first poll, so
          // no delay is honored, and a scripted throw would end a stalled loop deterministically.
          clock: ScriptedClock { _ in }
        )
      },
      tokenExchange: ChatGPTOAuthClient(http: http, wallDate: wallDate),
      catalog: ChatGPTModelCatalog(http: http),
      terminal: terminal,
      profileID: { identity }
    )
  }

  func statusWorkflow() -> AuthStatusWorkflow {
    AuthStatusWorkflow(
      bootstrap: AuthBootstrap(stateRoot: root, configuredModel: configuredModel),
      makeCredentialStore: makeCredentialStore,
      wallDate: { AcceptanceAuthFixture.wallNow }
    )
  }

  /// Seals the runtime secrets and stores a prior credential, leaving the root exactly as a previous
  /// successful login would have.
  func seedPriorLogin() throws {
    _ = try RuntimeSecretPreparer.prepare(stateRoot: root, environment: environment)
    try EncryptedLLMCredentialStore(stateRoot: root)
      .save(AcceptanceAuthFixture.priorCredential, providerID: .openAIChatGPT)
  }
}

func withAuthAcceptanceWorld<Value>(
  _ prefix: String,
  _ body: (inout AuthAcceptanceWorld) async throws -> Value
) async throws -> Value {
  let root = try makeTemporaryRoot(prefix: prefix)
  defer { try? FileManager.default.removeItem(at: root) }
  var world = AuthAcceptanceWorld(root: root)
  return try await body(&world)
}

/// Scripted wire fixtures for the acceptance world. Distinct from `OAuthFixture`/`AuthFixture` because
/// this suite states its answers as full `HTTPResult`s keyed by the pinned ChatGPT URLs.
enum AcceptanceAuthFixture {
  static let botToken = "acceptance-bot-token"
  static let accessToken = "acceptance-access-token"
  static let refreshToken = "acceptance-refresh-token"

  static let priorProfileID = UUID(uuid: (0xAC, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
  static let freshProfileID = UUID(uuid: (0xAC, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))

  static let wallNow = Date(timeIntervalSince1970: 1_800_000_000)

  static let priorCredential = StoredOAuthCredential(
    profileID: priorProfileID,
    accessToken: "prior-access-token",
    refreshToken: "prior-refresh-token",
    expiresAt: wallNow.addingTimeInterval(7200)
  )

  static func result(_ status: Int, _ body: String, headers: [String: String] = [:]) -> HTTPResult {
    HTTPResult(statusCode: status, headers: headers, body: Data(body.utf8))
  }

  /// The pinned URLs the real clients reach, in the order login walks them.
  static let orderedURLs = [
    ChatGPTProviderMetadata.userCodeURL,
    ChatGPTProviderMetadata.devicePollURL,
    ChatGPTProviderMetadata.tokenURL,
    ChatGPTProviderMetadata.modelsURL,
  ]

  static let happyResponses: [String: HTTPResult] = [
    ChatGPTProviderMetadata.userCodeURL: result(
      200,
      #"{"device_auth_id":"acc-device-auth-id","user_code":"ABCD-1234","interval":5}"#
    ),
    ChatGPTProviderMetadata.devicePollURL: result(
      200,
      #"{"authorization_code":"acc-auth-code","code_verifier":"acc-code-verifier"}"#
    ),
    ChatGPTProviderMetadata.tokenURL: result(
      200,
      #"{"access_token":"\#(accessToken)","refresh_token":"\#(refreshToken)","expires_in":3600}"#
    ),
    ChatGPTProviderMetadata.modelsURL: result(
      200,
      #"{"models":[{"slug":"gpt-5.4","priority":1},{"slug":"gpt-5.4-mini","priority":2}]}"#
    ),
  ]
}
