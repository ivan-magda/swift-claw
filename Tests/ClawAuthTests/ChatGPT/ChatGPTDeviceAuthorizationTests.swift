import ClawCore
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawAuth

/// Answers each call from a queue, so one URL can be pending on one poll and granted on the next —
/// the only shape the coordinator's loop ever produces. The shared `RecordingHTTPExecutor` keys on
/// the URL alone and so cannot vary an answer across the calls of a poll loop.
private actor SequencedHTTP: HTTPExecuting {
  enum Outcome: Sendable {
    case result(HTTPResult)
    case failure(@Sendable () -> any Error)
  }

  struct Exhausted: Error {}

  private var queued: [Outcome]
  private let repeatingLast: Outcome?

  /// The relative timeout of every call, in dispatch order — what the deadline cap is asserted on.
  private(set) var timeouts: [Duration] = []
  private(set) var urls: [String] = []

  init(_ queued: [Outcome], repeatingLast: Outcome? = nil) {
    self.queued = queued
    self.repeatingLast = repeatingLast
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    timeouts.append(request.timeout)
    urls.append(request.url)

    guard let outcome = queued.isEmpty ? repeatingLast : queued.removeFirst() else {
      throw Exhausted()
    }
    switch outcome {
    case .result(let result):
      return result
    case .failure(let makeFailure):
      throw makeFailure()
    }
  }
}

/// Every delay the coordinator asked its clock to sleep, in order.
private final class SleepLog: Sendable {
  private let entries = Mutex<[Duration]>([])

  func record(_ delay: Duration) {
    entries.withLock { recorded in
      recorded.append(delay)
    }
  }

  var recorded: [Duration] {
    entries.withLock { recorded in
      recorded
    }
  }
}

private enum Poll {
  static func deviceCode(interval: Int) -> SequencedHTTP.Outcome {
    .result(
      OAuthFixture.result(
        200,
        OAuthFixture.json(
          #""device_auth_id":"device-auth-id-1","user_code":"ABCD-1234","interval":\#(interval)"#
        )
      )
    )
  }

  static let pending = SequencedHTTP.Outcome.result(
    OAuthFixture.result(404, #"{"error":"authorization_pending"}"#)
  )

  static func throttled(retryAfter: String) -> SequencedHTTP.Outcome {
    .result(
      OAuthFixture.result(429, #"{"error":"slow_down"}"#, headers: ["Retry-After": retryAfter])
    )
  }

  static let granted = SequencedHTTP.Outcome.result(
    OAuthFixture.result(
      200,
      #"{"authorization_code":"auth-code-value","code_verifier":"code-verifier-value"}"#
    )
  )

  /// An owner who never approves, answering one poll more than a login that honors its deadline can
  /// reach. Finite on purpose: a coordinator that stopped honoring the window would poll forever
  /// against an endless queue and wedge the run, where this exhausts the queue and fails the test.
  static let neverApproved: [SequencedHTTP.Outcome] = [
    deviceCode(interval: 890), pending, pending, pending,
  ]

  /// A vendor that only ever says "slow down", finite for the same reason `neverApproved` is.
  static let alwaysThrottling: [SequencedHTTP.Outcome] = [
    deviceCode(interval: 5), throttled(retryAfter: "999999"), throttled(retryAfter: "999999"),
  ]
}

@Suite struct ChatGPTDeviceAuthorizationTests {
  // MARK: - Happy Path

  @Test func authorizeReturnsTheGrantOnceTheOwnerHasApprovedTheDevice() async throws {
    // given
    let http = SequencedHTTP([
      Poll.deviceCode(interval: 5), Poll.pending, Poll.pending, Poll.granted,
    ])
    let log = SleepLog()
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { delay in
        log.record(delay)
      }
    )

    // when
    let grant = try await coordinator.authorize { _ in }

    // then
    #expect(grant == OAuthFixture.grant)
    let urls = await http.urls
    #expect(
      urls == [
        ChatGPTProviderMetadata.userCodeURL,
        ChatGPTProviderMetadata.devicePollURL,
        ChatGPTProviderMetadata.devicePollURL,
        ChatGPTProviderMetadata.devicePollURL,
      ]
    )
  }

  @Test func authorizeReportsTheDeviceCodeOnceBeforeItStartsPolling() async throws {
    // given
    let http = SequencedHTTP([Poll.deviceCode(interval: 5), Poll.granted])
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { _ in }
    )
    let reported = Mutex<[ChatGPTDeviceCode]>([])
    let dispatchedWhenReported = Mutex<[String]>([])

    // when
    _ = try await coordinator.authorize { device in
      let urls = await http.urls
      reported.withLock { seen in
        seen.append(device)
      }
      dispatchedWhenReported.withLock { seen in
        seen = urls
      }
    }

    // then
    #expect(reported.withLock { $0 } == [OAuthFixture.device])
    // Nothing had been polled yet: the owner learns the code before the wait for it begins.
    #expect(dispatchedWhenReported.withLock { $0 } == [ChatGPTProviderMetadata.userCodeURL])
  }

  @Test func authorizeNeverSleepsWhenTheGrantArrivesOnTheFirstPoll() async throws {
    // given
    let http = SequencedHTTP([Poll.deviceCode(interval: 5), Poll.granted])
    let log = SleepLog()
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { delay in
        log.record(delay)
      }
    )

    // when
    _ = try await coordinator.authorize { _ in }

    // then
    #expect(log.recorded.isEmpty)
  }

  // MARK: - Pacing

  @Test func authorizeSleepsTheIntervalTheServerNamedBetweenPolls() async throws {
    // given
    let http = SequencedHTTP([
      Poll.deviceCode(interval: 7), Poll.pending, Poll.pending, Poll.granted,
    ])
    let log = SleepLog()
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { delay in
        log.record(delay)
      }
    )

    // when
    _ = try await coordinator.authorize { _ in }

    // then
    #expect(log.recorded == [.seconds(7), .seconds(7)])
  }

  @Test func authorizeWaitsOutAThrottleRatherThanSpinningOnIt() async throws {
    // given
    let http = SequencedHTTP([
      Poll.deviceCode(interval: 5), Poll.throttled(retryAfter: "30"), Poll.granted,
    ])
    let log = SleepLog()
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { delay in
        log.record(delay)
      }
    )

    // when
    _ = try await coordinator.authorize { _ in }

    // then
    #expect(log.recorded == [.seconds(30)])
  }

  /// A floor on what the coordinator will honor, wherever the delay came from. Nothing upstream can
  /// currently produce a sub-second interval — the wire parser refuses one outright — so this is the
  /// one place the rule can be stated and the one place a change to it can be caught.
  @Test(arguments: [
    (Duration.zero, ChatGPTProviderMetadata.minimumPollInterval),
    (Duration.seconds(-5), ChatGPTProviderMetadata.minimumPollInterval),
    (Duration.milliseconds(200), ChatGPTProviderMetadata.minimumPollInterval),
    (ChatGPTProviderMetadata.minimumPollInterval, ChatGPTProviderMetadata.minimumPollInterval),
    (Duration.seconds(7), Duration.seconds(7)),
  ])
  func aDelayIsNeverHonoredBelowThePinnedMinimum(requested: Duration, expected: Duration) {
    // given / when / then
    #expect(ChatGPTProviderMetadata.honoredPollDelay(requested) == expected)
  }

  // MARK: - The Login Window

  /// A stalled request must not be able to outrun the window the owner was promised, so each call's
  /// relative timeout is cut to what is left of the deadline.
  @Test func authorizeCapsEachRequestTimeoutToWhatIsLeftOfTheWindow() async throws {
    // given
    let http = SequencedHTTP(Poll.neverApproved)
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { _ in }
    )

    // when
    await #expect(throws: ChatGPTOAuthFailure.self) {
      try await coordinator.authorize { _ in }
    }

    // then
    // 900 seconds of window: the first two calls are bounded by the per-request ceiling, and the
    // third by the ten seconds the 890-second wait left behind.
    let timeouts = await http.timeouts
    #expect(timeouts == [.seconds(30), .seconds(30), .seconds(10)])
  }

  @Test func authorizeClampsAPollDelayToWhatIsLeftOfTheWindow() async throws {
    // given
    let http = SequencedHTTP(Poll.neverApproved)
    let log = SleepLog()
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { delay in
        log.record(delay)
      }
    )

    // when
    await #expect(throws: ChatGPTOAuthFailure.self) {
      try await coordinator.authorize { _ in }
    }

    // then
    #expect(log.recorded == [.seconds(890), .seconds(10)])
  }

  @Test func authorizeGivesUpOnceTheWindowHasClosed() async throws {
    // given
    let http = SequencedHTTP(Poll.neverApproved)
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { _ in }
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await coordinator.authorize { _ in }
    }

    // then
    #expect(failure == .deadlineExceeded)
  }

  @Test func aThrottleTooLongForTheWindowIsWaitedNoFurtherThanTheWindow() async throws {
    // given
    let http = SequencedHTTP(Poll.alwaysThrottling)
    let log = SleepLog()
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { delay in
        log.record(delay)
      }
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await coordinator.authorize { _ in }
    }

    // then
    #expect(log.recorded == [ChatGPTProviderMetadata.maximumLoginWait])
    #expect(failure == .deadlineExceeded)
  }

  // MARK: - Failure Propagation

  @Test func authorizeStopsAtTheFirstTerminalPollFailure() async throws {
    // given
    let http = SequencedHTTP([
      Poll.deviceCode(interval: 5), .result(OAuthFixture.result(400, #"{"error":"expired"}"#)),
    ])
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { _ in }
    )

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await coordinator.authorize { _ in }
    }

    // then
    #expect(failure?.isGrantRejected == true)
    let urls = await http.urls
    #expect(urls.count == 2)
  }

  @Test func cancellingTheWaitCancelsTheLoginRatherThanFailingIt() async throws {
    // given
    let http = SequencedHTTP([Poll.deviceCode(interval: 5)], repeatingLast: Poll.pending)
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { _ in
        throw CancellationError()
      }
    )

    // when / then
    await #expect(throws: CancellationError.self) {
      try await coordinator.authorize { _ in }
    }
  }

  @Test func cancellingARequestCancelsTheLoginRatherThanFailingIt() async throws {
    // given
    let http = SequencedHTTP([.failure { CancellationError() }])
    let coordinator = ChatGPTDeviceAuthorization(
      client: OAuthFixture.client(http),
      clock: ScriptedClock { _ in }
    )

    // when / then
    await #expect(throws: CancellationError.self) {
      try await coordinator.authorize { _ in }
    }
  }
}
