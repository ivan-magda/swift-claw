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

  /// The catalog spy the most recent `workflow()` wired, so a test can assert what authorization the
  /// catalog fetch was handed without hand-copying the whole workflow construction. A reference box
  /// keeps `AuthWorld` a copyable value while `workflow()` (non-mutating) records into it.
  private let builtCatalog = CatalogSpyBox()

  init(root: URL) {
    self.root = root
    environment = [EnvSecretStore.EnvKey.botToken: AuthFixture.botToken]
  }

  var paths: SecretStatePaths { SecretStatePaths(stateRoot: root) }

  /// The authorization the catalog fetch saw during the most recent `workflow().login()`.
  var seenCatalogAuthorization: LLMRequestAuthorization? {
    builtCatalog.seenAuthorization
  }

  /// The store as the owner's disk actually holds it, unrecorded — for assertions about what a
  /// command left behind rather than about what it did.
  var storedCredential: StoredOAuthCredential? {
    try? EncryptedLLMCredentialStore(stateRoot: root).load(providerID: .openAIChatGPT)
  }

  func workflow() -> AuthWorkflow {
    let stateRoot = root
    let effects = log
    let identity = profileID
    let device = deviceOutcome
    let catalog = ScriptedCatalog(outcome: catalogOutcome, log: log)
    builtCatalog.set(catalog)
    return AuthWorkflow(
      bootstrap: AuthBootstrap(stateRoot: root, configuredModel: configuredModel),
      runtimeSecrets: RealRuntimeSecrets(
        stateRoot: root,
        environment: environment,
        log: log
      ),
      mutationLock: mutationLock ?? ScriptedLock(failure: lockFailure, log: log),
      makeCredentialStore: {
        effects.record(.credentialStoreOpened)
        return ObservedCredentialStore(
          inner: EncryptedLLMCredentialStore(stateRoot: stateRoot),
          log: effects
        )
      },
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
      profileID: { identity },
      wallDate: { AuthFixture.now }
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

// MARK: - Login

@Suite struct AuthWorkflowLoginTests {
  /// The master ordering assertion. Each edge the spec pins is an adjacency in this one list, so a
  /// mutation that moves any step — the lock after the seal, the seal after the first request, the
  /// save before the exchange — changes it.
  @Test func loginRunsTheWholeSequenceInThePinnedOrder() async throws {
    try await withAuthWorld("auth-login-order") { world in
      // given
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(
        world.log.recorded == [
          .lockAcquired,
          .runtimeSecretsPrepared,
          .deviceAuthorizationStarted,
          .tokenExchanged,
          .credentialStoreOpened,
          .credentialSaved,
          .catalogFetched,
          .lockReleased,
        ]
      )
    }
  }

  @Test func loginPrintsTheUserCodeBeforeItStartsWaitingForApproval() async throws {
    try await withAuthWorld("auth-login-prompt") { world in
      // given
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains(AuthFixture.device.userCode))
      #expect(world.terminal.transcript.contains(ChatGPTProviderMetadata.verificationURL))
    }
  }

  /// The contract every renderer leans on: nothing left in `events` has been shown. Login streams as
  /// it goes, so by the time it returns it has nothing to hand over — which is what lets Task 18
  /// print `events` for all three commands without printing login's transcript a second time.
  @Test func loginReturnsNoEventsBecauseItHasAlreadyPresentedThemAll() async throws {
    try await withAuthWorld("auth-login-streamed") { world in
      // given
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(result.events.isEmpty)
      // The pairing: empty because the owner has already seen every line, not because login went
      // quiet. The terminal holds the whole ordered transcript.
      #expect(world.terminal.written.isEmpty == false)
      #expect(world.terminal.transcript.contains(AuthFixture.device.userCode))
      #expect(world.terminal.transcript.contains("Logged in to"))
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4"))
    }
  }

  /// The device-auth ID is a bearer of the pending authorization. It has no business in a transcript,
  /// and the fixture's is distinctive enough that any leak — through a mirror, an error, or an
  /// interpolation — shows up here.
  @Test func loginNeverPrintsTheDeviceAuthID() async throws {
    try await withAuthWorld("auth-login-redaction") { world in
      // given
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains(AuthFixture.deviceAuthID) == false)
      #expect(world.terminal.transcript.contains(AuthFixture.accessToken) == false)
      #expect(world.terminal.transcript.contains(AuthFixture.refreshToken) == false)
      // The pairing: the transcript really did carry the login's printable half.
      #expect(world.terminal.transcript.contains(AuthFixture.device.userCode))
    }
  }

  @Test func loginStoresTheExchangedPairUnderAFreshProfileID() async throws {
    try await withAuthWorld("auth-login-store") { world in
      // given
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      let stored = world.storedCredential
      #expect(stored?.profileID == AuthFixture.freshProfileID)
      #expect(stored?.accessToken == AuthFixture.accessToken)
      #expect(stored?.refreshToken == AuthFixture.refreshToken)
      #expect(stored?.expiresAt == AuthFixture.expiry)
    }
  }

  @Test func aSuccessfulReloginReplacesThePriorRecordWithANewProfile() async throws {
    try await withAuthWorld("auth-login-replace") { world in
      // given
      try world.seedPriorLogin()
      #expect(world.storedCredential?.profileID == AuthFixture.priorProfileID)
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.storedCredential?.profileID == AuthFixture.freshProfileID)
      #expect(world.storedCredential?.accessToken == AuthFixture.accessToken)
    }
  }

  // MARK: - The Lock Comes First

  @Test func aHeldLockStopsLoginBeforeItTouchesAnythingAtAll() async throws {
    try await withAuthWorld("auth-login-locked") { world in
      // given
      world.lockFailure = .held
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .commandFailure)
      // Nothing was sealed, nothing was asked of the vendor, nothing was written.
      #expect(world.log.recorded.isEmpty)
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path) == false)
      #expect(FileManager.default.fileExists(atPath: world.paths.runtimeEnvelope.path) == false)
      #expect(
        FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path) == false
      )
    }
  }

  @Test func aHeldLockTellsTheOwnerToStopTheDaemon() async throws {
    try await withAuthWorld("auth-login-locked-message") { world in
      // given
      world.lockFailure = .held
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(world.terminal.transcript.lowercased().contains("stop"))
      #expect(world.terminal.transcript.lowercased().contains("running"))
      #expect(world.terminal.written.allSatisfy { $0.destination == .standardError })
      // A refusal is presented like everything else login says, so it too has nothing left over.
      #expect(result.events.isEmpty)
    }
  }

  // MARK: - The Transition

  @Test func loginSealsTheEnvironmentSecretsBeforeItWritesACredential() async throws {
    try await withAuthWorld("auth-login-seal") { world in
      // given — an environment-backed root: neither encrypted artifact exists yet
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path) == false)
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path))
      #expect(FileManager.default.fileExists(atPath: world.paths.runtimeEnvelope.path))
      #expect(FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path))
      let sealIndex = try #require(world.log.recorded.firstIndex(of: .runtimeSecretsPrepared))
      let saveIndex = try #require(world.log.recorded.firstIndex(of: .credentialSaved))
      #expect(sealIndex < saveIndex)
    }
  }

  /// The gate that must hold before any egress: a root that cannot produce runtime secrets is a root
  /// login stops at, before it has told the vendor a device exists.
  @Test func missingRuntimeSecretsFailLoginBeforeItContactsTheVendor() async throws {
    try await withAuthWorld("auth-login-no-secrets") { world in
      // given — no Telegram token, so there is nothing to seal
      world.environment = [:]
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .secretLoadFailure)
      #expect(world.log.recorded == [.lockAcquired, .lockReleased])
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path) == false)
      #expect(FileManager.default.fileExists(atPath: world.paths.runtimeEnvelope.path) == false)
      #expect(
        FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path) == false
      )
    }
  }

  /// Exactly one encrypted artifact is the state login must never repair by minting the other. It
  /// fails closed with the daemon's own repair guidance, and creates nothing.
  @Test func aPartialEncryptedStateFailsClosedWithRepairGuidance() async throws {
    try await withAuthWorld("auth-login-partial") { world in
      // given — seal, then remove the envelope: the key alone remains
      _ = try RuntimeSecretPreparer.prepare(stateRoot: world.root, environment: world.environment)
      try FileManager.default.removeItem(at: world.paths.runtimeEnvelope)
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path))
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .secretLoadFailure)
      #expect(world.terminal.transcript.contains("clawd secrets seal"))
      #expect(world.log.recorded == [.lockAcquired, .lockReleased])
      // The half that was already there is untouched, and no credential joined it.
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path))
      #expect(FileManager.default.fileExists(atPath: world.paths.runtimeEnvelope.path) == false)
      #expect(
        FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path) == false
      )
    }
  }

  // MARK: - Nothing Is Saved Before The Exchange Succeeds

  @Test func aFailedExchangePreservesThePriorCredential() async throws {
    try await withAuthWorld("auth-login-exchange-fails") { world in
      // given
      try world.seedPriorLogin()
      world.exchangeOutcome = .failure {
        ChatGPTOAuthFailure.grantRejected(detail: "the code was already spent")
      }
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .commandFailure)
      #expect(world.storedCredential == AuthFixture.priorCredential)
      #expect(world.log.recorded.contains(.credentialSaved) == false)
    }
  }

  @Test func aCancelledApprovalPreservesThePriorCredential() async throws {
    try await withAuthWorld("auth-login-cancelled") { world in
      // given
      try world.seedPriorLogin()
      world.deviceOutcome = .failure { CancellationError() }
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .cancelled)
      #expect(world.storedCredential == AuthFixture.priorCredential)
      #expect(world.log.recorded.contains(.credentialSaved) == false)
    }
  }

  /// A pair with no refresh token cannot be stored into a refresh loop, so it is refused rather than
  /// saved — and refusing it must cost the owner nothing they already had.
  @Test func anExchangeWithoutARefreshTokenPreservesThePriorCredential() async throws {
    try await withAuthWorld("auth-login-no-refresh") { world in
      // given
      try world.seedPriorLogin()
      world.exchangeOutcome = .pair(
        ChatGPTTokenPair(
          accessToken: AuthFixture.accessToken,
          refreshToken: nil,
          expiresAt: AuthFixture.expiry
        )
      )
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .commandFailure)
      #expect(world.storedCredential == AuthFixture.priorCredential)
    }
  }

  @Test func aFailedDeviceAuthorizationNeverReachesTheExchange() async throws {
    try await withAuthWorld("auth-login-device-fails") { world in
      // given
      world.deviceOutcome = .failure { ChatGPTOAuthFailure.deadlineExceeded }
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .commandFailure)
      #expect(world.log.recorded.contains(.tokenExchanged) == false)
      #expect(world.log.recorded.contains(.credentialSaved) == false)
    }
  }

  // MARK: - Model Selection

  @Test func aNonInteractiveLoginTakesTheFirstReturnedModelAndExplainsIt() async throws {
    try await withAuthWorld("auth-login-default-model") { world in
      // given
      world.terminal = RecordingTerminal(isInteractive: false)
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4"))
    }
  }

  @Test func aConfiguredModelTheCatalogStillOffersIsTheDefault() async throws {
    try await withAuthWorld("auth-login-configured-model") { world in
      // given
      world.configuredModel = "openai-chatgpt/gpt-5.4-mini"
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4-mini"))
    }
  }

  @Test func aTerminalOwnerPicksAModelByNumber() async throws {
    try await withAuthWorld("auth-login-picked-model") { world in
      // given
      world.terminal = RecordingTerminal(isInteractive: true, lines: ["2"])
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4-mini"))
    }
  }

  @Test func anOutOfRangeAnswerIsAskedAgainRatherThanAccepted() async throws {
    try await withAuthWorld("auth-login-reask") { world in
      // given
      world.terminal = RecordingTerminal(isInteractive: true, lines: ["99", "1"])
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4"))
    }
  }

  /// A finite script that never answers: the loop must give up on its own bound and take the
  /// default, because a login that kept asking would wedge a run rather than fail it.
  @Test func anOwnerWhoNeverAnswersGetsTheDefaultRatherThanAnEndlessPrompt() async throws {
    try await withAuthWorld("auth-login-no-answer") { world in
      // given
      world.terminal = RecordingTerminal(isInteractive: true, lines: ["x", "y", "z", "w", "v"])
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4"))
    }
  }

  // MARK: - The Catalog Is Not The Login

  @Test func aCatalogFailureKeepsTheLoginAndPrintsTheManualForm() async throws {
    try await withAuthWorld("auth-login-catalog-fails") { world in
      // given
      world.catalogOutcome = .failure(.unavailable(detail: "the model list was not JSON"))
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.storedCredential?.profileID == AuthFixture.freshProfileID)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/<model>"))
    }
  }

  @Test func anEmptyCatalogKeepsTheLoginAndPrintsTheManualForm() async throws {
    try await withAuthWorld("auth-login-catalog-empty") { world in
      // given
      world.catalogOutcome = .models([])
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.storedCredential?.profileID == AuthFixture.freshProfileID)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/<model>"))
    }
  }

  @Test func theCatalogIsFetchedWithTheCredentialLoginJustStored() async throws {
    try await withAuthWorld("auth-login-catalog-bearer") { world in
      // given
      let workflow = world.workflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      let seen = try #require(world.seenCatalogAuthorization)
      #expect(seen.headers["Authorization"] == "Bearer \(AuthFixture.accessToken)")
    }
  }
}

// MARK: - Status

@Suite struct AuthWorkflowStatusTests {
  /// Status is a read. It takes no lock, opens no socket, and refreshes nothing — which is what lets
  /// an owner run it against a live daemon without fighting it for the state root.
  @Test func statusTakesNoLockAndContactsNobody() async throws {
    try await withAuthWorld("auth-status-quiet") { world in
      // given
      try world.seedPriorLogin()
      let workflow = world.workflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.exit == .success)
      #expect(world.log.recorded == [.credentialStoreOpened, .credentialLoaded])
      // The pairing that proves the log can record those effects at all: login does take the lock
      // and does reach the vendor, over these very same doubles.
      _ = await workflow.login()
      #expect(world.log.recorded.contains(.lockAcquired))
      #expect(world.log.recorded.contains(.deviceAuthorizationStarted))
    }
  }

  @Test func statusReportsPresenceExpiryAndFreshnessWithoutAnyTokenText() async throws {
    try await withAuthWorld("auth-status-present") { world in
      // given
      try world.seedPriorLogin()
      let workflow = world.workflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.exit == .success)
      #expect(result.transcript.contains(LLMProviderID.openAIChatGPT.rawValue))
      #expect(result.transcript.contains(AuthFixture.priorCredential.accessToken) == false)
      #expect(result.transcript.contains(AuthFixture.priorCredential.refreshToken) == false)
      #expect(result.transcript.contains(AuthFixture.priorProfileID.uuidString) == false)
    }
  }

  /// The 120-second skew belongs to one classifier. Status must read through it rather than restate
  /// it, or an owner can be told a token is fresh while the source that will spend it disagrees.
  @Test(arguments: [
    (Duration.seconds(3600), ChatGPTCredentialFreshness.fresh, "fresh"),
    (Duration.seconds(60), ChatGPTCredentialFreshness.expiring, "expiring"),
    (Duration.seconds(-60), ChatGPTCredentialFreshness.expired, "expired"),
  ])
  func statusNamesTheFreshnessClassTheSharedRuleWouldName(
    remaining: Duration,
    expected: ChatGPTCredentialFreshness,
    label: String
  ) async throws {
    try await withAuthWorld("auth-status-freshness") { world in
      // given
      let expiresAt = AuthFixture.now.addingTimeInterval(
        TimeInterval(remaining.components.seconds)
      )
      _ = try RuntimeSecretPreparer.prepare(stateRoot: world.root, environment: world.environment)
      try EncryptedLLMCredentialStore(stateRoot: world.root).save(
        StoredOAuthCredential(
          profileID: AuthFixture.priorProfileID,
          accessToken: "some-access-token",
          refreshToken: "some-refresh-token",
          expiresAt: expiresAt
        ),
        providerID: .openAIChatGPT
      )
      let workflow = world.workflow()

      // when
      let result = workflow.status()

      // then
      #expect(
        ChatGPTCredentialFreshness.classify(expiresAt: expiresAt, now: AuthFixture.now) == expected
      )
      #expect(result.exit == .success)
      #expect(result.transcript.contains(label))
    }
  }

  @Test func aLoggedOutStatusIsDescriptiveAndSucceeds() async throws {
    try await withAuthWorld("auth-status-logged-out") { world in
      // given — nothing has ever been stored here
      let workflow = world.workflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.exit == .success)
      #expect(result.transcript.lowercased().contains("logged out"))
    }
  }

  @Test func statusShowsTheConfiguredChatGPTModelWhenTheEnvironmentNamesOne() async throws {
    try await withAuthWorld("auth-status-model") { world in
      // given
      try world.seedPriorLogin()
      world.configuredModel = "openai-chatgpt/gpt-5.4"
      let workflow = world.workflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.transcript.contains("openai-chatgpt/gpt-5.4"))
    }
  }

  /// A model belonging to the fallback route says nothing about this provider's credential, so
  /// status must not present it as though it did.
  @Test func statusShowsNoModelWhenTheEnvironmentNamesAnotherRoutesModel() async throws {
    try await withAuthWorld("auth-status-other-model") { world in
      // given
      try world.seedPriorLogin()
      world.configuredModel = "gpt-4o"
      let workflow = world.workflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.transcript.contains("gpt-4o") == false)
    }
  }

  /// An envelope that exists but cannot be opened is not a logged-out state; it is a secret-load
  /// failure, and it must not read as "just log in again".
  @Test func anUnreadableCredentialEnvelopeIsASecretLoadFailure() async throws {
    try await withAuthWorld("auth-status-corrupt") { world in
      // given
      try world.seedPriorLogin()
      try Data("not an envelope".utf8).write(to: world.paths.credentialEnvelope)
      let workflow = world.workflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.exit == .secretLoadFailure)
    }
  }
}

// MARK: - Logout

@Suite struct AuthWorkflowLogoutTests {
  @Test func logoutTakesTheLockDeletesTheRecordAndReleasesIt() async throws {
    try await withAuthWorld("auth-logout") { world in
      // given
      try world.seedPriorLogin()
      let workflow = world.workflow()

      // when
      let result = workflow.logout()

      // then
      #expect(result.exit == .success)
      #expect(
        world.log.recorded == [
          .lockAcquired,
          .credentialStoreOpened,
          .credentialLoaded,
          .credentialDeleted,
          .lockReleased,
        ]
      )
      #expect(world.storedCredential == nil)
    }
  }

  @Test func logoutSaysTheDeletionIsLocalRatherThanARevocation() async throws {
    try await withAuthWorld("auth-logout-wording") { world in
      // given
      try world.seedPriorLogin()
      let workflow = world.workflow()

      // when
      let result = workflow.logout()

      // then
      let transcript = result.transcript.lowercased()
      #expect(transcript.contains("local"))
      #expect(transcript.contains("revocation") || transcript.contains("revoke"))
    }
  }

  @Test func logoutIsIdempotent() async throws {
    try await withAuthWorld("auth-logout-idempotent") { world in
      // given
      try world.seedPriorLogin()
      let workflow = world.workflow()
      #expect(workflow.logout().exit == .success)

      // when
      let second = workflow.logout()

      // then
      #expect(second.exit == .success)
      #expect(second.transcript.lowercased().contains("already logged out"))
    }
  }

  @Test func logoutOnARootThatNeverHeldACredentialSucceeds() async throws {
    try await withAuthWorld("auth-logout-never") { world in
      // given
      let workflow = world.workflow()

      // when
      let result = workflow.logout()

      // then
      #expect(result.exit == .success)
      #expect(result.transcript.lowercased().contains("already logged out"))
      #expect(world.log.recorded.contains(.credentialDeleted) == false)
    }
  }

  @Test func aHeldLockStopsLogoutBeforeItReadsOrDeletesAnything() async throws {
    try await withAuthWorld("auth-logout-locked") { world in
      // given
      try world.seedPriorLogin()
      world.lockFailure = .held
      let workflow = world.workflow()

      // when
      let result = workflow.logout()

      // then
      #expect(result.exit == .commandFailure)
      #expect(result.transcript.lowercased().contains("stop"))
      #expect(world.log.recorded.isEmpty)
      // The credential the daemon is using is exactly as it was.
      #expect(world.storedCredential == AuthFixture.priorCredential)
    }
  }
}
