import ClawCore
import ClawSecrets
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawAuth

// MARK: - Effects

/// Every side effect a command can have, in the order it had it. One totally ordered log across all
/// the collaborators is what turns "the lock came first" into an assertion rather than a claim: no
/// per-double flag can express that two effects happened in the wrong order.
enum AuthEffect: Sendable, Equatable {
  case lockAcquired
  case lockReleased
  case runtimeSecretsPrepared
  case deviceAuthorizationStarted
  case tokenExchanged
  case credentialStoreOpened
  case credentialLoaded
  case credentialSaved
  case credentialDeleted
  case catalogFetched
}

final class AuthEffectLog: Sendable {
  private let entries = Mutex<[AuthEffect]>([])

  func record(_ effect: AuthEffect) {
    entries.withLock { recorded in
      recorded.append(effect)
    }
  }

  var recorded: [AuthEffect] {
    entries.withLock { recorded in
      recorded
    }
  }
}

// MARK: - Doubles

struct ScriptedLock: AuthMutationLocking {
  let failure: AuthMutationLockFailure?
  let log: AuthEffectLog

  func acquire() throws -> AuthMutationLease {
    if let failure {
      throw failure
    }
    log.record(.lockAcquired)
    let effects = log
    return AuthMutationLease {
      effects.record(.lockReleased)
    }
  }
}

/// The real `RuntimeSecretPreparer` behind the auth seam. Task 08 already owns the seal, the real
/// decrypt, and the inode-guarded rollback; driving the genuine article is what makes the transition
/// assertions facts about the disk rather than about a stub's opinion.
struct RealRuntimeSecrets: AuthRuntimeSecretPreparing {
  let stateRoot: URL
  let environment: [String: String]
  let log: AuthEffectLog

  func prepare() throws {
    _ = try RuntimeSecretPreparer.prepare(stateRoot: stateRoot, environment: environment)
    log.record(.runtimeSecretsPrepared)
  }
}

/// The real encrypted store, with each call recorded. A stub would let "no credential file was
/// created" be true of a fiction; this keeps it true of the state root.
struct ObservedCredentialStore: LLMCredentialStore {
  let inner: EncryptedLLMCredentialStore
  let log: AuthEffectLog

  func load(
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) -> StoredOAuthCredential? {
    log.record(.credentialLoaded)
    return try inner.load(providerID: providerID)
  }

  func save(
    _ credential: StoredOAuthCredential,
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) {
    log.record(.credentialSaved)
    try inner.save(credential, providerID: providerID)
  }

  func delete(providerID: LLMProviderID) throws(LLMCredentialStoreError) {
    log.record(.credentialDeleted)
    try inner.delete(providerID: providerID)
  }
}

struct ScriptedDeviceAuthorization: ChatGPTDeviceAuthorizing {
  enum Outcome: Sendable {
    case granted(ChatGPTAuthorizationGrant)
    case failure(@Sendable () -> any Error)
  }

  let device: ChatGPTDeviceCode
  let outcome: Outcome
  let log: AuthEffectLog

  func authorize(
    onDeviceCode: @escaping @Sendable (ChatGPTDeviceCode) async -> Void
  ) async throws -> ChatGPTAuthorizationGrant {
    // Recorded before anything is reported: the question this marker answers is whether login
    // reached the vendor at all, not whether it got an answer.
    log.record(.deviceAuthorizationStarted)
    await onDeviceCode(device)
    switch outcome {
    case .granted(let grant):
      return grant
    case .failure(let makeFailure):
      throw makeFailure()
    }
  }
}

struct ScriptedExchange: ChatGPTOAuthExchanging {
  enum Outcome: Sendable {
    case pair(ChatGPTTokenPair)
    case failure(@Sendable () -> any Error)
  }

  let outcome: Outcome
  let log: AuthEffectLog

  func exchange(
    grant: ChatGPTAuthorizationGrant,
    timeout: Duration
  ) async throws -> ChatGPTTokenPair {
    log.record(.tokenExchanged)
    switch outcome {
    case .pair(let pair):
      return pair
    case .failure(let makeFailure):
      throw makeFailure()
    }
  }
}

final class ScriptedCatalog: ChatGPTModelCatalogFetching {
  enum Outcome: Sendable {
    case models([ChatGPTCatalogModel])
    case failure(ChatGPTCatalogFailure)
  }

  let outcome: Outcome
  let log: AuthEffectLog
  let seenAuthorization = Mutex<LLMRequestAuthorization?>(nil)

  init(outcome: Outcome, log: AuthEffectLog) {
    self.outcome = outcome
    self.log = log
  }

  func fetch(authorization: LLMRequestAuthorization) async throws -> [ChatGPTCatalogModel] {
    log.record(.catalogFetched)
    seenAuthorization.withLock { seen in
      seen = authorization
    }
    switch outcome {
    case .models(let models):
      return models
    case .failure(let failure):
      throw failure
    }
  }
}

/// A reference slot for the catalog spy `AuthWorld.workflow()` builds, so the value-type world can
/// expose what the catalog fetch saw without becoming non-copyable.
final class CatalogSpyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var catalog: ScriptedCatalog?

  func set(_ value: ScriptedCatalog) {
    lock.lock()
    defer { lock.unlock() }
    catalog = value
  }

  var seenAuthorization: LLMRequestAuthorization? {
    lock.lock()
    defer { lock.unlock() }
    return catalog?.seenAuthorization.withLock { $0 }
  }
}

final class RecordingTerminal: AuthTerminal {
  let isInteractive: Bool
  private let scripted: Mutex<[String]>
  private let events = Mutex<[AuthPresentationEvent]>([])

  init(isInteractive: Bool, lines: [String] = []) {
    self.isInteractive = isInteractive
    scripted = Mutex(lines)
  }

  func readLine() async throws -> String? {
    scripted.withLock { remaining in
      remaining.isEmpty ? nil : remaining.removeFirst()
    }
  }

  func write(_ event: AuthPresentationEvent) async {
    events.withLock { written in
      written.append(event)
    }
  }

  var written: [AuthPresentationEvent] {
    events.withLock { recorded in
      recorded
    }
  }
}

// MARK: - Fixtures

enum AuthFixture {
  static let botToken = "telegram-bot-token-value"
  static let accessToken = "access-token-value"
  static let refreshToken = "refresh-token-value"

  /// Never printable, and long enough to be recognisable if it ever leaked into a transcript.
  static let deviceAuthID = "device-auth-id-that-must-never-be-printed"

  /// Two fixed, distinguishable identities. What every replacement assertion turns on is only that
  /// the one login mints differs from the one already on disk.
  static let priorProfileID = UUID(uuid: (0xAA, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
  static let freshProfileID = UUID(uuid: (0xBB, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))

  static let now = Date(timeIntervalSince1970: 1_700_000_000)
  static let expiry = now.addingTimeInterval(3600)

  static let device = ChatGPTDeviceCode(
    deviceAuthID: deviceAuthID,
    userCode: "WDJB-MJHT",
    pollInterval: .seconds(5)
  )
  static let grant = ChatGPTAuthorizationGrant(
    authorizationCode: "authorization-code-value",
    codeVerifier: "code-verifier-value"
  )
  static let pair = ChatGPTTokenPair(
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresAt: expiry
  )
  static let catalog = [
    ChatGPTCatalogModel(slug: "gpt-5.4", priority: 1),
    ChatGPTCatalogModel(slug: "gpt-5.4-mini", priority: 2),
  ]

  /// A prior login this state root already holds. Every "the old credential survived" assertion is
  /// against this exact value.
  static let priorCredential = StoredOAuthCredential(
    profileID: priorProfileID,
    accessToken: "prior-access-token",
    refreshToken: "prior-refresh-token",
    expiresAt: now.addingTimeInterval(7200)
  )
}

// MARK: - World

/// One login's worth of collaborators over a real, disposable state root. Every knob defaults to the
/// happy path, so a test states only the edge it is about.
struct AuthWorld: Sendable {
  let root: URL
  let log = AuthEffectLog()

  var environment: [String: String]
  var configuredModel: String?
  var lockFailure: AuthMutationLockFailure?
  /// The real `flock` adapter when a test is about contention; the scripted lock otherwise.
  var mutationLock: (any AuthMutationLocking)?
  var terminal = RecordingTerminal(isInteractive: false)
  var deviceOutcome = ScriptedDeviceAuthorization.Outcome.granted(AuthFixture.grant)
  var exchangeOutcome = ScriptedExchange.Outcome.pair(AuthFixture.pair)
  var catalogOutcome = ScriptedCatalog.Outcome.models(AuthFixture.catalog)
  var profileID = AuthFixture.freshProfileID

  /// The catalog spy the most recent `loginWorkflow()` wired, so a test can assert what
  /// authorization the catalog fetch was handed without hand-copying the whole construction. A
  /// reference box keeps `AuthWorld` a copyable value while `loginWorkflow()` records into it.
  private let builtCatalog = CatalogSpyBox()

  init(root: URL) {
    self.root = root
    environment = [EnvSecretStore.EnvKey.botToken: AuthFixture.botToken]
  }

  var paths: SecretStatePaths { SecretStatePaths(stateRoot: root) }

  /// The authorization the catalog fetch saw during the most recent `loginWorkflow().login()`.
  var seenCatalogAuthorization: LLMRequestAuthorization? {
    builtCatalog.seenAuthorization
  }

  /// Loads the store as the owner's disk actually holds it, unrecorded. Read failures remain test
  /// failures rather than being mistaken for an absent credential.
  func loadStoredCredential() throws(LLMCredentialStoreError) -> StoredOAuthCredential? {
    try EncryptedLLMCredentialStore(stateRoot: root).load(providerID: .openAIChatGPT)
  }

  /// The store every command in this world opens, recording the open so a test can assert *when* it
  /// happened relative to the lock. Shared by all three builders, so no suite can be reading through
  /// a store the others are not.
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

  func loginWorkflow() -> AuthLoginWorkflow {
    let effects = log
    let identity = profileID
    let device = deviceOutcome
    let catalog = ScriptedCatalog(outcome: catalogOutcome, log: log)
    builtCatalog.set(catalog)
    return AuthLoginWorkflow(
      bootstrap: AuthBootstrap(stateRoot: root, configuredModel: configuredModel),
      runtimeSecrets: RealRuntimeSecrets(
        stateRoot: root,
        environment: environment,
        log: log
      ),
      mutationLock: mutationLock ?? ScriptedLock(failure: lockFailure, log: log),
      makeCredentialStore: makeCredentialStore,
      makeDeviceAuthorization: {
        ScriptedDeviceAuthorization(
          device: AuthFixture.device,
          outcome: device,
          log: effects
        )
      },
      tokenExchange: ScriptedExchange(outcome: exchangeOutcome, log: log),
      catalog: catalog,
      terminal: terminal,
      profileID: { identity }
    )
  }

  func statusWorkflow() -> AuthStatusWorkflow {
    AuthStatusWorkflow(
      bootstrap: AuthBootstrap(stateRoot: root, configuredModel: configuredModel),
      makeCredentialStore: makeCredentialStore,
      wallDate: { AuthFixture.now }
    )
  }

  func logoutWorkflow() -> AuthLogoutWorkflow {
    AuthLogoutWorkflow(
      mutationLock: mutationLock ?? ScriptedLock(failure: lockFailure, log: log),
      makeCredentialStore: makeCredentialStore
    )
  }

  /// Seals the runtime secrets and stores `AuthFixture.priorCredential`, leaving the root exactly as
  /// a previous successful login would have.
  func seedPriorLogin() throws {
    _ = try RuntimeSecretPreparer.prepare(stateRoot: root, environment: environment)
    try EncryptedLLMCredentialStore(stateRoot: root)
      .save(AuthFixture.priorCredential, providerID: .openAIChatGPT)
  }
}

func withAuthWorld<Value>(
  _ prefix: String,
  _ body: (inout AuthWorld) async throws -> Value
) async throws -> Value {
  let root = try makeTemporaryRoot(prefix: prefix)
  defer { try? FileManager.default.removeItem(at: root) }
  var world = AuthWorld(root: root)
  return try await body(&world)
}

/// The whole report as one string. Redaction claims are about everything an owner could see, so they
/// are asserted against everything the command emitted rather than a line a test picked. Only status
/// and logout answer through here: login has already presented its lines, and returns none.
extension AuthCommandResult {
  var transcript: String {
    events.map(\.text).joined(separator: "\n")
  }
}

/// Everything the owner actually saw, in order — which for login is the whole of it, since login
/// streams rather than returns. The two spellings are deliberately the same word: a test asserts
/// against whichever end the command in question presents through.
extension RecordingTerminal {
  var transcript: String {
    written.map(\.text).joined(separator: "\n")
  }
}
