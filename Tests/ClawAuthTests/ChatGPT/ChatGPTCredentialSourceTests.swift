import ClawCore
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawAuth

// MARK: - Doubles

/// A credential store that records every write and answers with whatever behavior the test last set.
/// Lock-backed rather than an actor because the seam is synchronous: the source must be able to save
/// without opening a suspension point, and a double that forced one would hide that.
final class RecordingCredentialStore: LLMCredentialStore, Sendable {
  private struct Ledger {
    var saved: [StoredOAuthCredential] = []
    var failure: LLMCredentialStoreError?
    var deletions = 0
  }

  private let ledger = Mutex(Ledger())

  init(failing failure: LLMCredentialStoreError? = nil) {
    ledger.withLock { current in
      current.failure = failure
    }
  }

  var saved: [StoredOAuthCredential] {
    ledger.withLock { current in
      current.saved
    }
  }

  /// Every accepted write, including the ones that later failed. `saved` counts attempts, not
  /// successes, which is what a retry-only-the-write assertion needs to see.
  var saveAttempts: Int { saved.count }

  func stopFailing() {
    ledger.withLock { current in
      current.failure = nil
    }
  }

  func startFailing(_ failure: LLMCredentialStoreError) {
    ledger.withLock { current in
      current.failure = failure
    }
  }

  func load(providerID: LLMProviderID) throws(LLMCredentialStoreError) -> StoredOAuthCredential? {
    nil
  }

  func save(
    _ credential: StoredOAuthCredential,
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) {
    let failure = ledger.withLock { current -> LLMCredentialStoreError? in
      current.saved.append(credential)
      return current.failure
    }
    if let failure {
      throw failure
    }
  }

  func delete(providerID: LLMProviderID) throws(LLMCredentialStoreError) {
    ledger.withLock { current in
      current.deletions += 1
    }
  }
}

/// A scripted refresh seam. The script is finite on purpose: past its last entry the double stops the
/// flight with a failure no test scripts, so a caller that refreshes more often than it should shows
/// up as a red assertion instead of spinning the suite.
actor ScriptedRefresh: ChatGPTOAuthRefreshing {
  /// Where a scripted call parks, which is how a test places shutdown either side of the point where
  /// the worker has a complete pair in hand.
  enum Hold: Sendable {
    case none
    /// Parks until released or cancelled, then reports the cancellation: a flight stopped before it
    /// decoded anything.
    case reportingCancellation(AsyncGate)
    /// Parks until released or cancelled and answers either way: the commit point, reached exactly
    /// when cancellation is racing the handoff.
    case answeringAfterCancellation(AsyncGate)
    /// Parks until released, cancellation or not: network work a shutdown must wait out.
    case ignoringCancellation(AsyncGate)
  }

  private var script: [Result<ChatGPTTokenPair, ChatGPTOAuthFailure>]
  private let hold: Hold
  private(set) var tokensSeen: [String] = []
  /// Latches once a flight has reached the seam, so a test can sequence on real network work.
  let started = AsyncGate()

  init(_ script: [Result<ChatGPTTokenPair, ChatGPTOAuthFailure>] = [], hold: Hold = .none) {
    self.script = script
    self.hold = hold
  }

  var callCount: Int { tokensSeen.count }

  func refresh(refreshToken: String, timeout: Duration) async throws -> ChatGPTTokenPair {
    tokensSeen.append(refreshToken)
    started.open()
    switch hold {
    case .none:
      break
    case .reportingCancellation(let gate):
      await gate.wait()
      try Task.checkCancellation()
    case .answeringAfterCancellation(let gate):
      await gate.wait()
    case .ignoringCancellation(let gate):
      await gate.waitIgnoringCancellation()
    }
    guard script.isEmpty == false else {
      throw ChatGPTOAuthFailure.grantRejected(detail: "unscripted refresh")
    }
    return try script.removeFirst().get()
  }
}

/// Counts callers as they enter `authorization()` and latches a gate on the nth.
///
/// Every caller reads the wall date once on entry, before the actor can be released, so the nth
/// reading is proof that n callers have been admitted and placed — parked on a flight or answered.
/// That is what lets a test open a refresh's gate knowing every waiter it means to test is already
/// registered, with no scheduling guess and no wall-clock window.
final class ArrivalCounter: Sendable {
  private let arrivals = Mutex(0)
  private let target: Int
  let reached = AsyncGate()

  init(target: Int) {
    self.target = target
  }

  var count: Int {
    arrivals.withLock { current in
      current
    }
  }

  var wallDate: @Sendable () -> Date {
    { [self] in
      let arrived = arrivals.withLock { current -> Int in
        current += 1
        return current
      }
      if arrived >= target {
        reached.open()
      }
      return CredentialFixture.wallNow
    }
  }
}

// MARK: - Fixture

/// The shared scripted values for both ChatGPT credential suites. Module-scoped so the source suite
/// and the shutdown suite cannot drift into disagreeing about what a stored credential looks like.
enum CredentialFixture {
  static let wallNow = OAuthFixture.wallNow
  /// Minted once and never asserted against a literal: what the cases care about is that a rotation
  /// carries the same local identity through, whatever it happens to be.
  static let profileID = UUID()

  static let firstGeneration = LLMCredentialGeneration(value: 1)
  static let secondGeneration = LLMCredentialGeneration(value: 2)

  static let rotatedAccess = "rotated-access-token"
  static let rotatedRefresh = "rotated-refresh-token"

  /// A token life measured from the fixed wall date, so a case names the exact side of the skew it
  /// means to sit on instead of a tolerance around the process clock.
  static func stored(
    access: String = OAuthFixture.accessToken,
    refresh: String = OAuthFixture.refreshToken,
    expiresIn seconds: Int
  ) -> StoredOAuthCredential {
    StoredOAuthCredential(
      profileID: profileID,
      accessToken: access,
      refreshToken: refresh,
      expiresAt: wallNow.addingTimeInterval(TimeInterval(seconds))
    )
  }

  static func pair(
    access: String = rotatedAccess,
    refresh: String? = rotatedRefresh,
    expiresIn seconds: Int = 3600
  ) -> ChatGPTTokenPair {
    ChatGPTTokenPair(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: wallNow.addingTimeInterval(TimeInterval(seconds))
    )
  }

  static func source(
    credential: StoredOAuthCredential?,
    store: RecordingCredentialStore = RecordingCredentialStore(),
    oauth: ScriptedRefresh = ScriptedRefresh(),
    clock: ScriptedClock = ScriptedClock { _ in },
    wallDate: @escaping @Sendable () -> Date = { wallNow }
  ) -> ChatGPTCredentialSource<ScriptedClock> {
    ChatGPTCredentialSource(
      initialCredential: credential,
      store: store,
      oauth: oauth,
      clock: clock,
      wallDate: wallDate
    )
  }
}

/// A caller held in flight, carrying its ending as a value instead of throwing it out of the task.
/// That is what lets a case park several callers at once and then ask each how it ended.
typealias Caller = Task<Result<LLMRequestAuthorization, any Error>, Never>

func authorizing(_ source: ChatGPTCredentialSource<ScriptedClock>) -> Caller {
  Task {
    do {
      return .success(try await source.authorization())
    } catch {
      return .failure(error)
    }
  }
}

extension ChatGPTCredentialError {
  var throttleDelay: Duration? {
    guard case .throttled(let retryAfter) = self else { return nil }
    return retryAfter
  }

  var unavailableDelay: Duration? {
    guard case .temporarilyUnavailable(let retryAfter, _) = self else { return nil }
    return retryAfter
  }
}

// MARK: - States and outcomes

@Suite(.timeLimit(.minutes(1)))
struct ChatGPTCredentialSourceTests {
  @Test func aMissingCredentialRequiresLoginWithoutTouchingTheStore() async throws {
    // given
    let store = RecordingCredentialStore()
    let source = CredentialFixture.source(credential: nil, store: store)

    // when
    let failure = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then — composition already loaded; the actor never reaches for a second read
    #expect(failure == .authenticationRequired)
    #expect(store.saveAttempts == 0)
  }

  @Test func aFreshCredentialAuthorizesAtGenerationOneWithNoNetwork() async throws {
    // given
    let oauth = ScriptedRefresh()
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 121),
      oauth: oauth
    )

    // when
    let authorization = try await source.authorization()

    // then
    #expect(authorization.generation == CredentialFixture.firstGeneration)
    #expect(authorization.headers["Authorization"] == "Bearer \(OAuthFixture.accessToken)")
    #expect(await oauth.callCount == 0)
  }

  /// The skew is a boundary, so both sides of it are named: one second inside is still fresh, and the
  /// boundary itself is already expiring. A single-sided case would pass against a skew of any width.
  @Test(arguments: [
    (121, false),
    (120, true),
    (1, true),
    (-1, true),
  ])
  func freshnessDecidesWhetherACallRefreshes(expiresIn: Int, refreshes: Bool) async throws {
    // given
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair())])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: expiresIn),
      oauth: oauth
    )

    // when
    let authorization = try await source.authorization()

    // then
    #expect(await oauth.callCount == (refreshes ? 1 : 0))
    let expected = refreshes ? CredentialFixture.rotatedAccess : OAuthFixture.accessToken
    #expect(authorization.headers["Authorization"] == "Bearer \(expected)")
  }

  @Test func aRotatedPairIsDurableBeforeItAuthorizes() async throws {
    // given
    let store = RecordingCredentialStore()
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair())])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      store: store,
      oauth: oauth
    )

    // when
    let authorization = try await source.authorization()

    // then — the write landed, and the generation moved only because it did
    let saved = try #require(store.saved.first)
    #expect(saved.accessToken == CredentialFixture.rotatedAccess)
    #expect(saved.refreshToken == CredentialFixture.rotatedRefresh)
    #expect(saved.profileID == CredentialFixture.profileID)
    #expect(authorization.generation == CredentialFixture.secondGeneration)
  }

  @Test func aWriteFailureWithholdsTheRotatedPairAndRetriesOnlyTheWrite() async throws {
    // given
    let store = RecordingCredentialStore(failing: .publicationFailed)
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair())])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      store: store,
      oauth: oauth
    )

    // when — the first call rotates and cannot publish
    let failure = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then — nothing was exposed
    #expect(failure == .persistenceFailed(.publicationFailed))

    // when — the store recovers and a later caller retries
    store.stopFailing()
    let authorization = try await source.authorization()

    // then — the retry spent no second rotation, only the pending write
    #expect(await oauth.callCount == 1)
    #expect(store.saveAttempts == 2)
    #expect(authorization.headers["Authorization"] == "Bearer \(CredentialFixture.rotatedAccess)")
    #expect(authorization.generation == CredentialFixture.secondGeneration)
  }

  /// The store is bounded but not interruptible: once a write begins it runs to the end, because the
  /// alternative is abandoning a half-written envelope. So the caller's cancellation has exactly one
  /// place to be honored — before the write starts.
  @Test func aCancelledCallerStartsNoPublication() async throws {
    // given — a rotated pair the store refused, leaving the next caller nothing to do but the write
    let store = RecordingCredentialStore(failing: .publicationFailed)
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair())])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      store: store,
      oauth: oauth
    )
    await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }
    #expect(store.saveAttempts == 1)
    store.stopFailing()

    // when — a caller that is already cancelled by the time it arrives retries the publication
    let admit = AsyncGate()
    let cancelled = Task { () -> Result<LLMRequestAuthorization, any Error> in
      await admit.waitIgnoringCancellation()
      do {
        return .success(try await source.authorization())
      } catch {
        return .failure(error)
      }
    }
    cancelled.cancel()
    admit.open()
    let outcome = await cancelled.value

    // then — it started no write, and left with the cancellation unreclassified
    #expect(throws: CancellationError.self) {
      try outcome.get()
    }
    #expect(store.saveAttempts == 1)

    // and — the pair is still there for a caller that did not cancel
    let authorization = try await source.authorization()
    #expect(store.saveAttempts == 2)
    #expect(authorization.headers["Authorization"] == "Bearer \(CredentialFixture.rotatedAccess)")
    #expect(await oauth.callCount == 1)
  }

  @Test func anOmittedRefreshTokenKeepsTheOldOne() async throws {
    // given
    let store = RecordingCredentialStore()
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair(refresh: nil))])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      store: store,
      oauth: oauth
    )

    // when
    _ = try await source.authorization()

    // then
    let saved = try #require(store.saved.first)
    #expect(saved.refreshToken == OAuthFixture.refreshToken)
    #expect(saved.accessToken == CredentialFixture.rotatedAccess)
    #expect(await oauth.tokensSeen == [OAuthFixture.refreshToken])
  }

  @Test func aRotatedPairKeepsBothPairsRedactable() async throws {
    // given
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair())])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      oauth: oauth
    )

    // when
    let authorization = try await source.authorization()

    // then — a request in flight under either pair still has its secrets scrubbed
    let values = Set(authorization.redactionValues)
    #expect(
      values.isSuperset(of: [
        CredentialFixture.rotatedAccess,
        CredentialFixture.rotatedRefresh,
        OAuthFixture.accessToken,
        OAuthFixture.refreshToken,
      ])
    )
  }

  // MARK: - The load-path token gate

  /// A stored token never met the wire client's gate, and the header builder does not examine what it
  /// is handed. Each case is a value that would otherwise compose into a bearer unexamined.
  @Test(arguments: [
    "",
    "token with spaces",
    "token\r\nX-Injected: 1",
    "token\u{0}embedded",
    "tokén-not-ascii",
    String(repeating: "a", count: ChatGPTProviderMetadata.maximumTokenBytes + 1),
  ])
  func anUnsafeStoredAccessTokenNeverBecomesAuthorization(access: String) async throws {
    // given
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair())])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(access: access, expiresIn: 3600),
      oauth: oauth
    )

    // when
    let failure = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then — no bearer, and no attempt to spend the rest of the record either
    #expect(failure == .authenticationRequired)
    #expect(await oauth.callCount == 0)
  }

  @Test(arguments: [
    "",
    "refresh with spaces",
    "refresh\r\nX-Injected: 1",
    String(repeating: "a", count: ChatGPTProviderMetadata.maximumTokenBytes + 1),
  ])
  func anUnsafeStoredRefreshTokenNeverBecomesAuthorization(refresh: String) async throws {
    // given — the access token is impeccable, so only the refresh token can fail the gate
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair())])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(refresh: refresh, expiresIn: 3600),
      oauth: oauth
    )

    // when
    let failure = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then
    #expect(failure == .authenticationRequired)
    #expect(await oauth.callCount == 0)
  }

  /// The positive half of the gate: the same shape of record, with tokens that pass, does authorize.
  /// Without it every case above would still pass against a source that simply never works.
  @Test func aSafeStoredCredentialAtTheTokenBoundAuthorizes() async throws {
    // given
    let atBound = String(repeating: "a", count: ChatGPTProviderMetadata.maximumTokenBytes)
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(access: atBound, expiresIn: 3600)
    )

    // when
    let authorization = try await source.authorization()

    // then
    #expect(authorization.headers["Authorization"] == "Bearer \(atBound)")
  }

  /// A rotated pair reaches the actor as a `ChatGPTTokenPair`, whose initializer is public — the wire
  /// client's gate is a convention outside this module, so the same bar is re-applied here.
  @Test func anUnsafeRotatedTokenNeverBecomesAuthorization() async throws {
    // given
    let store = RecordingCredentialStore()
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair(access: "rotated with spaces"))])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      store: store,
      oauth: oauth
    )

    // when
    let failure = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then — nothing unexamined was written, let alone published
    #expect(failure == .authenticationRequired)
    #expect(store.saveAttempts == 0)
  }

  // MARK: - Failure taxonomy

  @Test(arguments: [
    (ChatGPTOAuthFailure.grantRejected(detail: "invalid_grant"), 1),
    (ChatGPTOAuthFailure.grantRejected(detail: "status 401"), 1),
    (ChatGPTOAuthFailure.grantRejected(detail: "status 403"), 1),
  ])
  func aRejectedGrantRequiresLoginWithoutRetrying(
    failure: ChatGPTOAuthFailure,
    calls: Int
  ) async throws {
    // given
    let oauth = ScriptedRefresh([.failure(failure)])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      oauth: oauth
    )

    // when
    let thrown = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then
    #expect(thrown == .authenticationRequired)
    #expect(await oauth.callCount == calls)
  }

  @Test func aThrottledRefreshCoolsDownForTheNamedDelayAndStartsNoNetwork() async throws {
    // given
    let oauth = ScriptedRefresh([.failure(.throttled(retryAfter: .seconds(60)))])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      oauth: oauth
    )

    // when
    let thrown = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then
    #expect(thrown?.throttleDelay == .seconds(60))

    // when — a second caller arrives inside the window
    let second = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then — it waits out the remainder rather than adding to the vendor's load
    #expect(second?.throttleDelay == .seconds(60))
    #expect(await oauth.callCount == 1)
  }

  @Test func anUnnamedThrottleCoolsDownForTheCeiling() async throws {
    // given
    let oauth = ScriptedRefresh([.failure(.throttled(retryAfter: nil))])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      oauth: oauth
    )

    // when
    let thrown = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then
    #expect(thrown?.throttleDelay == .seconds(30))
  }

  @Test func transportFailuresSpendTheRetryBudgetThenCoolDownForTheCeiling() async throws {
    // given — one entry more than the budget would spend, so an unbounded retry ends in a distinct
    // failure rather than a spin
    let oauth = ScriptedRefresh([
      .failure(.transport(detail: "reset")),
      .failure(.transport(detail: "reset")),
      .failure(.transport(detail: "reset")),
      .failure(.transport(detail: "reset")),
    ])
    let backoffs = Mutex<[Duration]>([])
    let clock = ScriptedClock { delay in
      backoffs.withLock { current in
        current.append(delay)
      }
    }
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      oauth: oauth,
      clock: clock
    )

    // when
    let thrown = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then
    #expect(await oauth.callCount == 3)
    #expect(backoffs.withLock { current in current } == [.seconds(1), .seconds(2)])
    #expect(thrown?.unavailableDelay == .seconds(30))
  }

  @Test(arguments: [
    ChatGPTOAuthFailure.malformedResponse(detail: "not JSON"),
    ChatGPTOAuthFailure.deadlineExceeded,
  ])
  func anUnusableAnswerCoolsDownWithoutRetrying(failure: ChatGPTOAuthFailure) async throws {
    // given
    let oauth = ScriptedRefresh([.failure(failure)])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      oauth: oauth
    )

    // when
    let thrown = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then — retrying an identical request would earn an identical answer
    #expect(thrown?.unavailableDelay == .seconds(30))
    #expect(await oauth.callCount == 1)
  }

  @Test func theFirstCallerAfterCooldownExpiryStartsOneNewFlight() async throws {
    // given
    let oauth = ScriptedRefresh([
      .failure(.throttled(retryAfter: .seconds(60))),
      .success(CredentialFixture.pair()),
    ])
    let clock = ScriptedClock { _ in }
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      oauth: oauth,
      clock: clock
    )
    await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // when — virtual time, not the wall clock, carries the source past its window
    try await clock.sleep(for: .seconds(61))
    let authorization = try await source.authorization()

    // then
    #expect(await oauth.callCount == 2)
    #expect(authorization.headers["Authorization"] == "Bearer \(CredentialFixture.rotatedAccess)")
  }

  // MARK: - Generation-aware rejection

  @Test func aStaleGenerationRejectionIsIgnored() async throws {
    // given
    let oauth = ScriptedRefresh()
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 3600),
      oauth: oauth
    )
    let live = try await source.authorization()

    // when — a 401 from a request that authorized under an older snapshot lands late
    await source.reject(
      generation: LLMCredentialGeneration(value: live.generation.value - 1),
      disposition: .authenticationRequired
    )

    // then — the current snapshot is untouched
    let authorization = try await source.authorization()
    #expect(authorization.generation == CredentialFixture.firstGeneration)
    #expect(await oauth.callCount == 0)
  }

  @Test func aMatchingFirstRejectionForcesARefreshOfAnOtherwiseFreshToken() async throws {
    // given
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair())])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 3600),
      oauth: oauth
    )

    // when
    await source.reject(generation: CredentialFixture.firstGeneration, disposition: .refresh)
    let authorization = try await source.authorization()

    // then
    #expect(await oauth.callCount == 1)
    #expect(authorization.generation == CredentialFixture.secondGeneration)
    #expect(authorization.headers["Authorization"] == "Bearer \(CredentialFixture.rotatedAccess)")
  }

  @Test func aMatchingSecondRejectionLatchesAndSilencesTheNetwork() async throws {
    // given
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair())])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 3600),
      oauth: oauth
    )

    // when
    await source.reject(generation: CredentialFixture.firstGeneration, disposition: .refresh)
    await source.reject(
      generation: CredentialFixture.firstGeneration,
      disposition: .authenticationRequired
    )

    // then — terminal, and no later turn starts another refresh loop
    let first = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }
    let second = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }
    #expect(first == .authenticationRequired)
    #expect(second == .authenticationRequired)
    #expect(await oauth.callCount == 0)
  }

  // MARK: - Single flight

  @Test func concurrentCallersShareOneFlightAndOneAnswer() async throws {
    // given — a flight that cannot finish until its gate opens, and an arrival count that only
    // reaches three once every caller is placed
    let release = AsyncGate()
    defer { release.open() }
    let arrivals = ArrivalCounter(target: 3)
    let oauth = ScriptedRefresh(
      [.success(CredentialFixture.pair())],
      hold: .ignoringCancellation(release)
    )
    let store = RecordingCredentialStore()
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      store: store,
      oauth: oauth,
      wallDate: arrivals.wallDate
    )

    // when
    let callers = (0..<3).map { _ in
      authorizing(source)
    }
    await arrivals.reached.wait()
    release.open()
    var answers: [LLMRequestAuthorization] = []
    for caller in callers {
      answers.append(try await caller.value.get())
    }

    // then — one rotation, one write, one answer
    #expect(await oauth.callCount == 1)
    #expect(store.saveAttempts == 1)
    #expect(Set(answers.map(\.generation)) == [CredentialFixture.secondGeneration])
    #expect(
      answers.allSatisfy { answer in
        answer.headers["Authorization"] == "Bearer \(CredentialFixture.rotatedAccess)"
      }
    )
  }

  @Test func cancellingOneWaiterLeavesTheFlightAndTheOthersAlone() async throws {
    // given
    let release = AsyncGate()
    defer { release.open() }
    let arrivals = ArrivalCounter(target: 3)
    let oauth = ScriptedRefresh(
      [.success(CredentialFixture.pair())],
      hold: .ignoringCancellation(release)
    )
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      oauth: oauth,
      wallDate: arrivals.wallDate
    )
    let stayers = (0..<2).map { _ in
      authorizing(source)
    }
    let leaver = authorizing(source)
    await arrivals.reached.wait()

    // when — one waiter walks away while the shared flight is still parked
    leaver.cancel()
    let leaverOutcome = await leaver.value

    // then — it left with the cancellation it raised, and it took nothing with it
    #expect(throws: CancellationError.self) {
      try leaverOutcome.get()
    }
    release.open()
    for stayer in stayers {
      let authorization = try await stayer.value.get()
      #expect(authorization.generation == CredentialFixture.secondGeneration)
    }
    #expect(await oauth.callCount == 1)
  }

  /// The finalizer is guarded by the flight's operation ID rather than by the state alone, so a
  /// completion belonging to an older flight cannot save, publish, bump the generation, clear the
  /// flight, or resume its waiters. Driven directly: no sequence of public calls can produce two
  /// overlapping flights, which is the point — the guard is what keeps it that way.
  @Test func aStaleFlightCannotFinalizeANewerOperation() async throws {
    // given
    let release = AsyncGate()
    defer { release.open() }
    let arrivals = ArrivalCounter(target: 1)
    let store = RecordingCredentialStore()
    let oauth = ScriptedRefresh(
      [.success(CredentialFixture.pair())],
      hold: .ignoringCancellation(release)
    )
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      store: store,
      oauth: oauth,
      wallDate: arrivals.wallDate
    )
    let caller = authorizing(source)
    await arrivals.reached.wait()

    // when — a completion arrives quoting an operation this actor is not running
    await source.finalize(
      flightID: 9999,
      result: .success(CredentialFixture.pair(access: "stale-access", refresh: "stale-refresh"))
    )

    // then — nothing was written and nobody was resumed
    #expect(store.saveAttempts == 0)

    // when — the live flight finishes
    release.open()
    let authorization = try await caller.value.get()

    // then — the live operation's own answer is what lands
    #expect(store.saved.map(\.accessToken) == [CredentialFixture.rotatedAccess])
    #expect(authorization.generation == CredentialFixture.secondGeneration)
    #expect(authorization.headers["Authorization"] == "Bearer \(CredentialFixture.rotatedAccess)")
  }
}
