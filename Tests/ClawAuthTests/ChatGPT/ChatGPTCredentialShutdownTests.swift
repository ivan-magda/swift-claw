import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawAuth

/// The shutdown commit rule, one ordering per case. Every case places shutdown on a named side of the
/// worker's commit point — the instant it holds a complete, validated replacement pair — because that
/// is the only boundary that decides whether a rotation is accepted or abandoned.
@Suite(.timeLimit(.minutes(1)))
struct ChatGPTCredentialShutdownTests {
  @Test func shutdownBeforeAPairIsDecodedAcceptsNothing() async throws {
    // given — a flight parked short of any answer, which reports the cancellation it is handed
    let release = AsyncGate()
    defer { release.open() }
    let store = RecordingCredentialStore()
    let oauth = ScriptedRefresh(
      [.success(CredentialFixture.pair())],
      hold: .reportingCancellation(release)
    )
    let arrivals = ArrivalCounter(target: 1)
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      store: store,
      oauth: oauth,
      wallDate: arrivals.wallDate
    )
    let waiter = authorizing(source)
    await arrivals.reached.wait()
    await oauth.started.wait()

    // when
    try await source.shutdown()

    // then — no local value was accepted, and the waiter left with the cancellation it was given
    #expect(store.saveAttempts == 0)
    let outcome = await waiter.value
    #expect(throws: CancellationError.self) {
      try outcome.get()
    }
  }

  @Test func aPairDecodedAsShutdownCancelsIsStillCommitted() async throws {
    // given — a flight whose answer arrives exactly when cancellation reaches it, so the handoff and
    // the cancellation are genuinely racing rather than merely ordered by the test
    let commitPoint = AsyncGate()
    defer { commitPoint.open() }
    let store = RecordingCredentialStore()
    let oauth = ScriptedRefresh(
      [.success(CredentialFixture.pair())],
      hold: .answeringAfterCancellation(commitPoint)
    )
    let arrivals = ArrivalCounter(target: 1)
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      store: store,
      oauth: oauth,
      wallDate: arrivals.wallDate
    )
    let waiter = authorizing(source)
    await arrivals.reached.wait()
    await oauth.started.wait()

    // when — shutdown cancels the worker, which releases it holding a complete pair
    try await source.shutdown()

    // then — the rotation is durable even though the task that produced it was cancelled
    let saved = try #require(store.saved.first)
    #expect(saved.accessToken == CredentialFixture.rotatedAccess)
    #expect(saved.refreshToken == CredentialFixture.rotatedRefresh)

    // and — the committed pair is never handed to a caller
    let outcome = await waiter.value
    #expect(throws: CancellationError.self) {
      try outcome.get()
    }
    let late = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }
    #expect(late == .shuttingDown)
  }

  @Test func shutdownWaitsOutNetworkWorkBeforeReturning() async throws {
    // given — a flight that ignores cancellation, standing in for a transport still mid-exchange.
    // Composition closes the HTTP client only after this call returns, so returning early would pull
    // the transport out from under a rotation that is still being decided.
    let release = AsyncGate()
    defer { release.open() }
    let store = RecordingCredentialStore()
    let oauth = ScriptedRefresh(
      [.success(CredentialFixture.pair())],
      hold: .ignoringCancellation(release)
    )
    let arrivals = ArrivalCounter(target: 1)
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      store: store,
      oauth: oauth,
      wallDate: arrivals.wallDate
    )
    let waiter = authorizing(source)
    await arrivals.reached.wait()
    await oauth.started.wait()

    // when
    let finished = CompletionFlag()
    let shutdownTask = Task {
      try await source.shutdown()
      await finished.markDone()
    }
    // A yield lets an (incorrect) shutdown that abandoned its worker surface, with no wall-clock
    // window to lose.
    await Task.yield()
    let returnedWhileRefreshInFlight = await finished.done
    release.open()
    try await shutdownTask.value

    // then
    #expect(returnedWhileRefreshInFlight == false)
    #expect(store.saveAttempts == 1)
    let outcome = await waiter.value
    #expect(throws: CancellationError.self) {
      try outcome.get()
    }
  }

  @Test func shutdownFromPendingPersistenceRetriesOnlyTheWrite() async throws {
    // given — a rotation that reached the actor but could not be written
    let store = RecordingCredentialStore(failing: .publicationFailed)
    let oauth = ScriptedRefresh([.success(CredentialFixture.pair())])
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      store: store,
      oauth: oauth
    )
    let thrown = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }
    #expect(thrown == .persistenceFailed(.publicationFailed))

    // when — the store recovers before the daemon stops
    store.stopFailing()
    try await source.shutdown()

    // then — shutdown flushed the pair it was holding, and spent no second rotation to do it
    #expect(store.saveAttempts == 2)
    #expect(store.saved.last?.accessToken == CredentialFixture.rotatedAccess)
    #expect(await oauth.callCount == 1)
  }

  @Test func aPersistentWriteFailureIsReportedRatherThanSwallowed() async throws {
    // given
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

    // when
    let thrown = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.shutdown()
    }

    // then — a stop that lost a rotation never reports success
    #expect(thrown == .persistenceFailed(.publicationFailed))
    #expect(store.saveAttempts == 2)
  }

  /// The clean-stop counterpart: without it, every case above would still pass against a `shutdown()`
  /// that threw unconditionally.
  @Test func aQuietShutdownSucceedsAndThenRefusesNewCallers() async throws {
    // given
    let oauth = ScriptedRefresh()
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 3600),
      oauth: oauth
    )
    _ = try await source.authorization()

    // when
    try await source.shutdown()

    // then
    let thrown = await #expect(throws: ChatGPTCredentialError.self) {
      try await source.authorization()
    }
    #expect(thrown == .shuttingDown)
    #expect(await oauth.callCount == 0)
  }

  @Test func shutdownResumesEveryWaiterExactlyOnce() async throws {
    // given
    let release = AsyncGate()
    defer { release.open() }
    let arrivals = ArrivalCounter(target: 4)
    let oauth = ScriptedRefresh(
      [.success(CredentialFixture.pair())],
      hold: .reportingCancellation(release)
    )
    let source = CredentialFixture.source(
      credential: CredentialFixture.stored(expiresIn: 10),
      oauth: oauth,
      wallDate: arrivals.wallDate
    )
    let waiters = (0..<4).map { _ in
      authorizing(source)
    }
    await arrivals.reached.wait()

    // when
    try await source.shutdown()

    // then — a waiter resumed twice would trap the checked continuation before this returns
    for waiter in waiters {
      let outcome = await waiter.value
      #expect(throws: CancellationError.self) {
        try outcome.get()
      }
    }
  }
}
