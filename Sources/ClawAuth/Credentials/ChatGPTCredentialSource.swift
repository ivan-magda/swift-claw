import ClawCore
import Foundation

// MARK: - Outcomes

/// What a caller is told when the source cannot hand it authorization. Every case is safe to show an
/// owner: remote text has already been sanitized and redacted before it reaches a `detail`, and the
/// two waiting cases carry the bound on the wait rather than an open-ended "try later".
public enum ChatGPTCredentialError: Error, Sendable, Equatable {
  /// The stored credential is finished — revoked, spent, or never usable. Only a new login repairs
  /// it, and no amount of waiting will.
  case authenticationRequired
  /// The vendor asked to be left alone. The credential is intact; this is quota, not identity.
  case throttled(retryAfter: Duration)
  /// The refresh did not complete for a reason that may not recur.
  case temporarilyUnavailable(retryAfter: Duration, detail: String)
  /// A rotated pair exists but could not be written, so it is deliberately not being used.
  case persistenceFailed(LLMCredentialStoreError)
  case shuttingDown
}

// MARK: - Policy

/// What this daemon does about a refresh that fails, as opposed to what the vendor's protocol says.
/// It lives apart from the pinned provider metadata for that reason: none of it is negotiated, and
/// none of it is a value the vendor publishes.
package enum ChatGPTRefreshPolicy {
  /// Total attempts one flight may spend on failures that might not recur. Low on purpose: a token
  /// endpoint that is down does not get better for being asked harder, and a flight is holding
  /// every waiter for the whole budget.
  package static let attemptBudget = 3

  /// The longest a caller is ever told to wait on this source's own initiative, and the wait it
  /// picks when a throttle names none. It exists so a wave of new turns arriving at an unhealthy
  /// token endpoint cannot become a wave of requests.
  static let maximumCooldown = Duration.seconds(30)

  /// Doubling, and clamped to the same ceiling as a cooldown so no single retry can outlast the
  /// wait a caller would have been given for giving up entirely.
  static func backoff(afterAttempt attempt: Int) -> Duration {
    // The shift is clamped rather than trusted to `attemptBudget`: a shift wide enough to overflow
    // is undefined, and a budget raised in another decade must not turn a wait into a crash. The
    // ceiling below already flattens everything past this point, so the clamp costs no behaviour.
    let doublings = min(attempt - 1, 5)
    return min(.seconds(1 << doublings), maximumCooldown)
  }
}

// MARK: - Validated credential

/// A stored pair that has passed the header-safety gate, and the only shape the source will hold.
///
/// The gate matters most on the load path: bytes read back from the store never met the wire client's
/// checks, and the header builder does not examine what it is handed — an empty access token composes
/// into `Bearer ` and a token carrying a newline folds in a header of the caller's choosing. Making
/// this the only way in means no arrangement of the actor's states can reach the builder with a value
/// nobody looked at.
struct ChatGPTValidatedCredential: Sendable, Equatable {
  let stored: StoredOAuthCredential

  private init(validated stored: StoredOAuthCredential) {
    self.stored = stored
  }

  var profileID: UUID { stored.profileID }
  var accessToken: String { stored.accessToken }
  var refreshToken: String { stored.refreshToken }
  var expiresAt: Date { stored.expiresAt }

  init?(_ stored: StoredOAuthCredential) {
    guard
      Self.isSpendable(stored.accessToken),
      Self.isSpendable(stored.refreshToken)
    else {
      return nil
    }
    self.stored = stored
  }

  /// Rotation in one place, so the three things that must happen together cannot come apart: the
  /// local profile identity survives, an omitted refresh token means the old one still stands rather
  /// than that it was taken away, and the result faces the same gate as anything off the disk.
  init?(rotating previous: ChatGPTValidatedCredential, with pair: ChatGPTTokenPair) {
    self.init(
      StoredOAuthCredential(
        profileID: previous.profileID,
        accessToken: pair.accessToken,
        refreshToken: pair.refreshToken ?? previous.refreshToken,
        expiresAt: pair.expiresAt
      )
    )
  }

  func requiringRefresh() -> Self {
    Self(
      validated: StoredOAuthCredential(
        profileID: profileID,
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: Date(timeIntervalSince1970: 0)
      )
    )
  }

  private static func isSpendable(_ token: String) -> Bool {
    ChatGPTWireValues.headerSafeToken(
      token,
      maxBytes: ChatGPTProviderMetadata.maximumTokenBytes
    ) != nil
  }
}

// MARK: - Source

/// The live ChatGPT credential: one owner of the stored pair, one refresh in flight at a time, and
/// one place where a rotation becomes real.
///
/// Composition loads and validates the initial credential before construction, so a load is never a
/// second implicit flight, and the store stays synchronous so that installing a refreshed pair opens
/// no reentrancy window between deciding to publish and having published.
public actor ChatGPTCredentialSource<ClockType: Clock>: LLMCredentialSource
where ClockType.Duration == Duration {
  private let store: any LLMCredentialStore
  private let oauth: any ChatGPTOAuthRefreshing
  private let clock: ClockType
  private let wallDate: @Sendable () -> Date

  private var state: State
  private var waiters: [Int: CheckedContinuation<LLMRequestAuthorization, any Error>] = [:]
  private var lastWaiterID = 0
  private var lastFlightID: UInt64 = 0
  /// The pair the current one replaced. Requests authorized under it may still be on the wire, so
  /// their diagnostics must still be able to scrub it. One pair deep, which bounds the set.
  private var priorPair: TokenPair?

  public init(
    initialCredential: StoredOAuthCredential?,
    store: any LLMCredentialStore,
    oauth: any ChatGPTOAuthRefreshing,
    clock: ClockType,
    wallDate: @escaping @Sendable () -> Date
  ) {
    self.store = store
    self.oauth = oauth
    self.clock = clock
    self.wallDate = wallDate

    switch initialCredential {
    case nil:
      state = .missing
    case .some(let stored):
      // A record whose tokens cannot be spent is not a record a refresh can rescue: the refresh
      // token is one of the two values that just failed. Only a new login repairs it.
      state =
        ChatGPTValidatedCredential(stored).map { credential in
          .ready(credential: credential, generation: Self.initialGeneration)
        } ?? .authenticationRequired
    }
  }

  public func authorization() async throws -> LLMRequestAuthorization {
    let now = wallDate()
    switch state {
    case .stopping:
      throw ChatGPTCredentialError.shuttingDown
    case .missing, .authenticationRequired:
      throw ChatGPTCredentialError.authenticationRequired
    case .pendingPersistence(let pending):
      return try await retryPublication(of: pending)
    case .refreshing(let flight):
      return try await join(flight)
    case .cooldown(let cooling):
      let remaining = clock.now.duration(to: cooling.until)
      guard remaining <= .zero else {
        throw cooling.failure(retryAfter: remaining)
      }
      return try await join(startFlight(from: cooling.credential, replacing: cooling.generation))
    case .ready(let credential, let generation):
      let freshness = ChatGPTCredentialFreshness.classify(expiresAt: credential.expiresAt, now: now)
      guard freshness != .fresh else {
        return authorization(for: credential, generation: generation)
      }
      return try await join(startFlight(from: credential, replacing: generation))
    }
  }

  /// A verdict about a snapshot, so it only counts while that snapshot is the one being spent: a late
  /// 401 from a request that authorized two rotations ago has nothing to say about the token now on
  /// the wire.
  public func reject(
    generation: LLMCredentialGeneration,
    disposition: LLMCredentialRejection
  ) async {
    switch state {
    case .ready(let credential, let current) where current == generation:
      switch disposition {
      case .refresh:
        let pending = Pending(
          credential: credential.requiringRefresh(),
          baseGeneration: current,
          purpose: .forceRefresh
        )
        do {
          try commit(pending)
          state = .ready(credential: pending.credential, generation: current)
        } catch {
          state = .pendingPersistence(pending)
        }
      case .authenticationRequired:
        state = .authenticationRequired
      }
    case .cooldown(let cooling) where cooling.generation == generation:
      // A cooldown already ends in a refresh, so `.refresh` asks for what is coming. A terminal
      // verdict is worth latching now: it saves the wait and the request that would follow it.
      if disposition == .authenticationRequired {
        state = .authenticationRequired
      }
    default:
      // A refresh in flight is already the answer to `.refresh`, and its own result decides whether
      // the credential is finished. A pending write must not be dropped on a verdict about the
      // generation it is replacing.
      break
    }
  }

  /// The lifecycle's commit point. It runs to a durable answer or a typed failure — never to a quiet
  /// success that lost a rotation or a required refresh marker.
  public func shutdown() async throws {
    let retained = closeAdmission()
    // Cancelled but not forgotten: the worker may be holding a complete pair, and its finalizer is
    // matched by the flight record this keeps.
    retained.flight?.task.cancel()
    await retained.flight?.task.value

    guard case .stopping(let stopping) = state, let pending = stopping.pending else {
      return
    }
    do {
      try commit(pending)
    } catch {
      throw ChatGPTCredentialError.persistenceFailed(error)
    }
    state = .stopping(Stopping())
  }

  /// The one operation-ID-guarded finalizer: the only place that may write, publish, move the
  /// generation, clear the flight, or resume waiters. Waiters do no post-await cleanup, so a
  /// completion from a flight this actor is no longer running cannot disturb the one it is.
  func finalize(flightID: UInt64, result: Result<ChatGPTTokenPair, any Error>) {
    guard let flight = flight(matching: flightID) else {
      return
    }
    switch result {
    case .success(let pair):
      accept(pair, from: flight)
    case .failure(let error):
      settle(error, from: flight)
    }
  }
}

// MARK: - State

private extension ChatGPTCredentialSource {
  static var initialGeneration: LLMCredentialGeneration { LLMCredentialGeneration(value: 1) }

  struct TokenPair: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
  }

  struct Flight {
    let id: UInt64
    let baseGeneration: LLMCredentialGeneration
    /// The snapshot the flight spends. Immutable and carried by value, so nothing the actor does
    /// while the flight runs can change what it is redeeming.
    let credential: ChatGPTValidatedCredential
    let task: Task<Void, Never>
  }

  struct Pending {
    let credential: ChatGPTValidatedCredential
    /// The generation a rotation replaces, or a refresh marker keeps until that refresh completes.
    /// Held rather than applied because only a durable rotated pair may advance authorization.
    let baseGeneration: LLMCredentialGeneration
    let purpose: Purpose

    enum Purpose: Sendable {
      case publishRotation
      case forceRefresh
    }
  }

  struct Cooling {
    let credential: ChatGPTValidatedCredential
    let generation: LLMCredentialGeneration
    let reason: Reason
    let until: ClockType.Instant

    enum Reason: Sendable, Equatable {
      case throttled
      case unavailable(detail: String)
    }

    func failure(retryAfter: Duration) -> ChatGPTCredentialError {
      switch reason {
      case .throttled:
        .throttled(retryAfter: retryAfter)
      case .unavailable(let detail):
        .temporarilyUnavailable(retryAfter: retryAfter, detail: detail)
      }
    }
  }

  /// What a stopping source is still holding. Admission is already closed; these are the obligations
  /// that outlive it.
  struct Stopping {
    var flight: Flight?
    var pending: Pending?
  }

  enum State {
    case missing
    case ready(credential: ChatGPTValidatedCredential, generation: LLMCredentialGeneration)
    case refreshing(Flight)
    case pendingPersistence(Pending)
    case cooldown(Cooling)
    case authenticationRequired
    case stopping(Stopping)
  }

  var isStopping: Bool {
    if case .stopping = state { return true }
    return false
  }

  /// A flight record is reachable from exactly two states, and only under its own ID.
  func flight(matching flightID: UInt64) -> Flight? {
    switch state {
    case .refreshing(let flight) where flight.id == flightID:
      return flight
    case .stopping(let stopping) where stopping.flight?.id == flightID:
      return stopping.flight
    default:
      return nil
    }
  }
}

// MARK: - Publication

private extension ChatGPTCredentialSource {
  /// A caller retrying credential state it did not start. It retries only the write: a rotated pair
  /// must not spend its refresh token twice, while a refresh marker starts its flight only after the
  /// rejected token is durably unusable across process replacement.
  func retryPublication(of pending: Pending) async throws -> LLMRequestAuthorization {
    // The write is bounded but not free, and it is not cancellable once begun — so the check belongs
    // here, before it starts, rather than inside a store that would have to abandon a half-written
    // envelope to honor it.
    try Task.checkCancellation()
    do {
      try commit(pending)
    } catch {
      throw ChatGPTCredentialError.persistenceFailed(error)
    }
    switch pending.purpose {
    case .publishRotation:
      return install(pending)
    case .forceRefresh:
      return try await join(
        startFlight(from: pending.credential, replacing: pending.baseGeneration)
      )
    }
  }

  func commit(_ pending: Pending) throws(LLMCredentialStoreError) {
    try store.save(pending.credential.stored, providerID: ChatGPTProviderMetadata.providerID)
  }

  /// Publication proper: the generation moves only here, and only after the write returned.
  func install(_ pending: Pending) -> LLMRequestAuthorization {
    let generation = LLMCredentialGeneration(value: pending.baseGeneration.value + 1)
    state = .ready(credential: pending.credential, generation: generation)
    return authorization(for: pending.credential, generation: generation)
  }

  func authorization(
    for credential: ChatGPTValidatedCredential,
    generation: LLMCredentialGeneration
  ) -> LLMRequestAuthorization {
    let base = ChatGPTProviderMetadata.authorization(
      accessToken: credential.accessToken,
      generation: generation
    )
    var values = base.redactionValues
    append(credential.refreshToken, to: &values)
    if let priorPair {
      append(priorPair.accessToken, to: &values)
      append(priorPair.refreshToken, to: &values)
    }
    return LLMRequestAuthorization(
      headers: base.headers,
      redactionValues: values,
      generation: base.generation
    )
  }

  func append(_ value: String, to values: inout [String]) {
    guard values.contains(value) == false else { return }
    values.append(value)
  }
}

// MARK: - Flights

private extension ChatGPTCredentialSource {
  /// Starts exactly one flight and records it before anything can suspend, so the next caller through
  /// the door finds it rather than starting a second.
  ///
  /// Unlike `retryPublication`, this does not check for cancellation first: a caller that is already
  /// cancelled still starts the flight and only then abandons it in `join`. That asymmetry is
  /// deliberate. The rotation is under way and its answer lands durably for whoever comes next,
  /// whereas a publication retry would spend a rotation the vendor may already have consumed.
  func startFlight(
    from credential: ChatGPTValidatedCredential,
    replacing generation: LLMCredentialGeneration
  ) -> Flight {
    lastFlightID += 1
    let flightID = lastFlightID
    let task = Task {
      await self.runRefresh(flightID: flightID, snapshot: credential)
    }
    let flight = Flight(
      id: flightID,
      baseGeneration: generation,
      credential: credential,
      task: task
    )
    state = .refreshing(flight)
    return flight
  }

  /// The refresh worker. It is deliberately outside the actor: only its finalizer touches state, and
  /// only through the actor's own door.
  nonisolated func runRefresh(flightID: UInt64, snapshot: ChatGPTValidatedCredential) async {
    var attempt = 1
    while true {
      do {
        let pair = try await oauth.refresh(
          refreshToken: snapshot.refreshToken,
          timeout: ChatGPTProviderMetadata.requestTimeout
        )
        // The commit point. Cancellation may already have been delivered; the handoff happens
        // anyway, because a decoded pair means the vendor has rotated whether we stop or not.
        await finalize(flightID: flightID, result: .success(pair))
        return
      } catch {
        guard Self.isWorthRetrying(error), attempt < ChatGPTRefreshPolicy.attemptBudget else {
          await finalize(flightID: flightID, result: .failure(error))
          return
        }
        do {
          try await clock.sleep(for: ChatGPTRefreshPolicy.backoff(afterAttempt: attempt))
        } catch let interruption {
          await finalize(flightID: flightID, result: .failure(interruption))
          return
        }
        attempt += 1
      }
    }
  }

  nonisolated static func isWorthRetrying(_ error: any Error) -> Bool {
    guard case .transport = error as? ChatGPTOAuthFailure else { return false }
    return true
  }

  func join(_ flight: Flight) async throws -> LLMRequestAuthorization {
    lastWaiterID += 1
    let waiterID = lastWaiterID
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Runs on this actor with no suspension between the state check that chose this flight and
        // the registration, so a finalizer cannot slip past a caller on its way in.
        waiters[waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.abandon(waiterID: waiterID)
      }
    }
  }

  /// One waiter leaving. It resumes only itself: the flight belongs to every other waiter too, and
  /// none of them asked to stop.
  func abandon(waiterID: Int) {
    waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
  }

  func resumeWaiters(with result: Result<LLMRequestAuthorization, any Error>) {
    let parked = waiters
    waiters.removeAll()
    for waiter in parked.values {
      waiter.resume(with: result)
    }
  }
}

// MARK: - Finalization

private extension ChatGPTCredentialSource {
  func accept(_ pair: ChatGPTTokenPair, from flight: Flight) {
    guard let rotated = ChatGPTValidatedCredential(rotating: flight.credential, with: pair) else {
      // The old refresh token may already be spent, so there is nothing left to retry with. A source
      // on its way down says so instead: there is no next caller here to tell.
      guard isStopping == false else {
        state = .stopping(Stopping())
        return
      }
      finish(.authenticationRequired, resuming: .authenticationRequired)
      return
    }
    priorPair = TokenPair(
      accessToken: flight.credential.accessToken,
      refreshToken: flight.credential.refreshToken
    )
    let pending = Pending(
      credential: rotated,
      baseGeneration: flight.baseGeneration,
      purpose: .publishRotation
    )
    do {
      try commit(pending)
    } catch {
      withhold(pending, after: error)
      return
    }
    guard isStopping == false else {
      state = .stopping(Stopping())
      return
    }
    resumeWaiters(with: .success(install(pending)))
  }

  /// A rotated pair that could not be written. It is kept whole and unused: exposing it would let a
  /// restart authorize with a token the disk has never heard of.
  func withhold(_ pending: Pending, after failure: LLMCredentialStoreError) {
    guard isStopping == false else {
      state = .stopping(Stopping(flight: nil, pending: pending))
      return
    }
    state = .pendingPersistence(pending)
    resumeWaiters(with: .failure(ChatGPTCredentialError.persistenceFailed(failure)))
  }

  func settle(_ error: any Error, from flight: Flight) {
    guard isStopping == false else {
      state = .stopping(Stopping())
      return
    }
    // A cancellation is not special-cased here. The only one this actor ever delivers comes from
    // shutdown, which sets the stopping state the guard above already caught; any cancellation
    // reaching this point is one a waiter never asked for, so it earns the transient cooldown below
    // rather than a false "you cancelled" handed to live turns.
    guard let cooling = cooling(for: error, from: flight) else {
      finish(.authenticationRequired, resuming: .authenticationRequired)
      return
    }
    state = .cooldown(cooling)
    resumeWaiters(
      with: .failure(cooling.failure(retryAfter: clock.now.duration(to: cooling.until)))
    )
  }

  func finish(_ next: State, resuming failure: ChatGPTCredentialError) {
    state = next
    resumeWaiters(with: .failure(failure))
  }

  /// The wait a failure earns, or nil when it earns none because only a login will do.
  ///
  /// Nothing here interpolates the raw error: an unrecognized one may carry a path or key material in
  /// its description, and the two `detail`s that are used arrived already sanitized and redacted.
  func cooling(for error: any Error, from flight: Flight) -> Cooling? {
    let reason: Cooling.Reason
    let delay: Duration
    switch error as? ChatGPTOAuthFailure {
    case .grantRejected:
      return nil
    case .throttled(let retryAfter):
      reason = .throttled
      delay = retryAfter ?? ChatGPTRefreshPolicy.maximumCooldown
    case .malformedResponse(let detail), .transport(let detail):
      reason = .unavailable(detail: detail)
      delay = ChatGPTRefreshPolicy.maximumCooldown
    // `.deadlineExceeded` names a login window that closed, which only the device-code poll can
    // reach; a refresh cannot raise it. It shares the catch-all rather than claiming an event of
    // its own so no caller is ever told a story about a deadline this path does not keep.
    case nil, .deadlineExceeded:
      reason = .unavailable(detail: "the refresh did not complete")
      delay = ChatGPTRefreshPolicy.maximumCooldown
    }
    return Cooling(
      credential: flight.credential,
      generation: flight.baseGeneration,
      reason: reason,
      until: clock.now.advanced(by: delay)
    )
  }
}

// MARK: - Shutdown

private extension ChatGPTCredentialSource {
  /// Closes the door and resumes everyone already inside, keeping only what the commit rule still
  /// owes: an active flight, or credential state that was never written.
  func closeAdmission() -> Stopping {
    let retained: Stopping
    switch state {
    case .refreshing(let flight):
      retained = Stopping(flight: flight, pending: nil)
    case .pendingPersistence(let pending):
      retained = Stopping(flight: nil, pending: pending)
    case .stopping(let stopping):
      retained = stopping
    case .missing, .ready, .cooldown, .authenticationRequired:
      retained = Stopping()
    }
    state = .stopping(retained)
    resumeWaiters(with: .failure(CancellationError()))
    return retained
  }
}
