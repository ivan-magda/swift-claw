import ClawAuth
import ClawCore
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawLLM

/// The shared Responses attempt engine: one exposure reducer, one wire-attempt budget across every
/// retry class, and a retry boundary that closes at the first SSE `data:` byte. Every HTTP outcome is
/// scripted at the unmanaged seam and every delay runs on a manual clock, so nothing here waits on
/// real time.
@Suite struct ChatGPTResponsesAttemptEngineTests {
  // MARK: - Success

  @Test(.timeLimit(.minutes(1)))
  func aCleanSuccessStreamsDeltasAndCompletesOnOneAttempt() async throws {
    // given
    let harness = Harness(steps: [.stream(okHead, Fixtures.successChunks())])

    // when
    let outcome = await harness.run()

    // then — exactly one wire attempt, the delta reaches the sink, and the reply is stamped normally
    #expect(await harness.attemptCount == 1)
    #expect(await harness.deltas == ["hi"])
    let response = try requireCompleted(outcome)
    #expect(response.content == "hi")
    #expect(response.providerState?.issuer == harness.normalIdentity.issuer)
  }

  // MARK: - 401 sequence

  @Test(.timeLimit(.minutes(1)))
  func aClean401RefreshesWithTheRequestGenerationThenRetriesOnce() async throws {
    // given — the first attempt's head is a clean 401, the retry succeeds
    let harness = Harness(
      steps: [
        .stream(head(401), Fixtures.errorChunks(message: "expired")),
        .stream(okHead, Fixtures.successChunks()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — one refresh rejection carrying the first request's generation, then a second attempt
    #expect(await harness.attemptCount == 2)
    let rejections = await harness.credentials.rejections
    #expect(rejections == [.init(generation: .init(value: 1), disposition: .refresh)])
    _ = try requireCompleted(outcome)
  }

  @Test(.timeLimit(.minutes(1)))
  func aSecondClean401LatchesAuthenticationRequired() async throws {
    // given — both attempts answer with a clean 401
    let harness = Harness(
      steps: [
        .stream(head(401), Fixtures.errorChunks(message: "expired")),
        .stream(head(401), Fixtures.errorChunks(message: "still expired")),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — refresh on the first generation, then a terminal latch on the second
    #expect(await harness.attemptCount == 2)
    let rejections = await harness.credentials.rejections
    #expect(
      rejections == [
        .init(generation: .init(value: 1), disposition: .refresh),
        .init(generation: .init(value: 2), disposition: .authenticationRequired),
      ]
    )
    #expect(failureCause(outcome) == .authenticationRequired)
    #expect(accounting(outcome) == .notStarted)
  }

  // MARK: - Access and quota

  @Test(.timeLimit(.minutes(1)))
  func an403IsAccessDeniedWithoutRefreshOrRetry() async throws {
    // given
    let harness = Harness(steps: [.stream(head(403), Fixtures.errorChunks(message: "no route"))])

    // when
    let outcome = await harness.run()

    // then — one attempt, no credential rejection, and no re-login prompt
    #expect(await harness.attemptCount == 1)
    #expect(await harness.credentials.rejections.isEmpty)
    #expect(failureCause(outcome) == .accessDenied)
    #expect(accounting(outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [(60, 30), (10, 10)])
  func aClean429IsQuotaLimitedHonoringTheClampedRetryAfter(
    timeout: Int,
    expectedClamp: Int
  ) async throws {
    // given — a 429 asks for 300 seconds, retried once then exhausted at budget 2
    let harness = Harness(
      steps: [
        .stream(head(429, retryAfter: 300), Fixtures.errorChunks(message: "slow down")),
        .stream(head(429, retryAfter: 300), Fixtures.errorChunks(message: "slow down")),
      ],
      retryBudget: 2,
      requestTimeoutSeconds: timeout
    )

    // when
    let outcome = await harness.run()

    // then — the honored delay and the surfaced hint are both clamped to min(30, timeout)
    #expect(await harness.attemptCount == 2)
    #expect(await harness.delays == [Double(expectedClamp)])
    #expect(failureCause(outcome) == .quotaLimited(retryAfterSeconds: expectedClamp))
    #expect(accounting(outcome) == .notStarted)
  }

  // MARK: - Transient and transport retries

  @Test(.timeLimit(.minutes(1)))
  func a408RetriesWithBoundedBackoffThenSucceeds() async throws {
    // given
    let harness = Harness(
      steps: [
        .stream(head(408), Fixtures.errorChunks(message: "timeout")),
        .stream(okHead, Fixtures.successChunks()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — one bounded backoff, then a clean success
    #expect(await harness.attemptCount == 2)
    #expect(await harness.delays == [0.5])
    _ = try requireCompleted(outcome)
  }

  @Test(.timeLimit(.minutes(1)))
  func a5xxExhaustsTheBudgetAsRetryable() async throws {
    // given
    let harness = Harness(
      steps: [
        .stream(head(500), Fixtures.errorChunks(message: "boom")),
        .stream(head(500), Fixtures.errorChunks(message: "boom")),
      ],
      retryBudget: 2
    )

    // when
    let outcome = await harness.run()

    // then
    #expect(await harness.attemptCount == 2)
    #expect(failureCause(outcome) == .retryable(status: 500, message: "boom"))
    #expect(accounting(outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func aDefinitelyNotSentTransportFailureRetries() async throws {
    // given — nothing could have been written, so the attempt is replayable
    let harness = Harness(
      steps: [
        .transportFailure(
          HTTPTransportFailure(disposition: .definitelyNotSent, safeMessage: "refused")
        ),
        .stream(okHead, Fixtures.successChunks()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then
    #expect(await harness.attemptCount == 2)
    #expect(await harness.delays == [0.5])
    _ = try requireCompleted(outcome)
  }

  @Test(.timeLimit(.minutes(1)))
  func aMayHaveBeenSentTransportFailureIsNotRetried() async throws {
    // given — an ambiguous send that a retry could double-charge
    let harness = Harness(
      steps: [
        .transportFailure(
          HTTPTransportFailure(disposition: .mayHaveBeenSent, safeMessage: "dropped")
        ),
        .stream(okHead, Fixtures.successChunks()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — a single attempt, conservative accounting, and no second dispatch of the success step
    #expect(await harness.attemptCount == 1)
    #expect(await harness.delays.isEmpty)
    #expect(accounting(outcome) == .mayHaveStarted(observedCompletionTokens: 0))
  }

  // MARK: - One shared budget

  @Test(.timeLimit(.minutes(1)))
  func oneBudgetCountsEveryRetryClassAcrossTheWholeCall() async throws {
    // given — three different retry classes, then a success the budget must never reach
    let harness = Harness(
      steps: [
        .stream(head(401), Fixtures.errorChunks(message: "expired")),
        .stream(head(500), Fixtures.errorChunks(message: "boom")),
        .transportFailure(
          HTTPTransportFailure(disposition: .definitelyNotSent, safeMessage: "refused")
        ),
        .stream(okHead, Fixtures.successChunks()),
      ],
      retryBudget: 3
    )

    // when
    let outcome = await harness.run()

    // then — a budget that reset between classes would reach the 4th step and complete; a shared one
    // stops at three wire attempts and fails
    #expect(await harness.attemptCount == 3)
    #expect(failureCause(outcome) == .retryable(status: nil, message: "refused"))
    #expect(accounting(outcome) == .notStarted)
  }

  // MARK: - Invalid encrypted content recovery

  @Test(.timeLimit(.minutes(1)))
  func aCleanInvalidEncryptedContentRetriesOnceStateFreeInANewEpoch() async throws {
    // given — a clean head rejection naming poisoned replay state, then a success
    let harness = Harness(
      steps: [
        .stream(
          head(400),
          Fixtures.errorChunks(code: "invalid_encrypted_content", message: "bad state")
        ),
        .stream(okHead, Fixtures.successChunks()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — two attempts, the recovery attempt drops prior state, and the reply carries the new epoch
    #expect(await harness.attemptCount == 2)
    #expect(harness.includePriorStateLog == [true, false])
    let response = try requireCompleted(outcome)
    #expect(response.providerState?.issuer == harness.recoveryIdentity.issuer)
    #expect(harness.recoveryIdentity.issuer != harness.normalIdentity.issuer)
  }

  @Test(.timeLimit(.minutes(1)))
  func theStateFreeRecoveryCountsAgainstTheBudget() async throws {
    // given — recovery then a 500, at a budget of two
    let harness = Harness(
      steps: [
        .stream(
          head(400),
          Fixtures.errorChunks(code: "invalid_encrypted_content", message: "bad state")
        ),
        .stream(head(500), Fixtures.errorChunks(message: "boom")),
      ],
      retryBudget: 2
    )

    // when
    let outcome = await harness.run()

    // then — the recovery consumed one attempt, so the 500 exhausts the budget rather than retrying
    #expect(await harness.attemptCount == 2)
    #expect(failureCause(outcome) == .retryable(status: 500, message: "boom"))
  }

  // MARK: - The retry boundary

  @Test(.timeLimit(.minutes(1)))
  func aFailureAfterTheFirstDataByteIsNeverReplayed() async throws {
    // given — a 2xx stream that emits a data event and then drops the connection
    let harness = Harness(
      steps: [
        .streamFailure(
          okHead,
          Fixtures.partialDataChunks(),
          TransportFailure(message: "dropped mid-stream")
        ),
        .stream(okHead, Fixtures.successChunks()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — the boundary closed on the first data byte, so the drop is not retried, and the
    // generated deltas are carried as a conservative lower bound
    #expect(await harness.attemptCount == 1)
    #expect(isConservative(accounting(outcome)))
  }

  @Test(.timeLimit(.minutes(1)))
  func anInvalidEncryptedContentAfterDataDoesNotTriggerRecovery() async throws {
    // given — the poisoned-state error arrives in-band, after a data byte has streamed
    let harness = Harness(
      steps: [
        .stream(okHead, Fixtures.dataThenErrorChunks(code: "invalid_encrypted_content")),
        .stream(okHead, Fixtures.successChunks()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — no state-free recovery once the boundary has closed; degrade conservatively instead
    #expect(await harness.attemptCount == 1)
    #expect(harness.includePriorStateLog == [true])
    #expect(isConservative(accounting(outcome)))
  }

  @Test(.timeLimit(.minutes(1)))
  func aTerminalFreeStreamEOFIsConservativeAndNotRetried() async throws {
    // given — a 2xx stream that ends without ever stating an outcome
    let harness = Harness(
      steps: [
        .stream(okHead, Fixtures.partialDataChunks()),
        .stream(okHead, Fixtures.successChunks()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then
    #expect(await harness.attemptCount == 1)
    #expect(isConservative(accounting(outcome)))
  }

  // MARK: - Cancellation

  @Test(.timeLimit(.minutes(1)))
  func cancellationBeforeAuthorizationIsNotStarted() async {
    // given
    let harness = Harness(steps: [.stream(okHead, Fixtures.successChunks())])

    // when — the run task is already cancelled before it can authorize
    let outcome = await Task {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      return await harness.run()
    }
    .value

    // then — no wire attempt, no debit
    #expect(await harness.attemptCount == 0)
    #expect(outcome == .cancelled(.notStarted))
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellationDuringBackoffIsNotStarted() async {
    // given — a retryable head, and a clock that reports cancellation the moment backoff begins
    let harness = Harness(
      steps: [.stream(head(500), Fixtures.errorChunks(message: "boom"))],
      cancelDuringSleep: true
    )

    // when
    let outcome = await harness.run()

    // then — the clean head had already reset exposure, so a cancelled backoff owes no usage
    #expect(await harness.attemptCount == 1)
    #expect(outcome == .cancelled(.notStarted))
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellationAfterDataIsConservative() async {
    // given — a stream whose first delta the consumer refuses by cancelling
    let harness = Harness(
      steps: [.stream(okHead, Fixtures.successChunks())],
      failOnFirstDelta: CancellationError()
    )

    // when
    let outcome = await harness.run()

    // then — the model may have been asked, so cancellation is conservative rather than raw no-debit
    if case .cancelled(let disposition) = outcome {
      #expect(disposition == .mayHaveStarted(observedCompletionTokens: 0))
    } else {
      Issue.record("expected a conservative cancellation, got \(outcome)")
    }
  }

  // MARK: - Credential failures

  @Test(.timeLimit(.minutes(1)))
  func aThrottledCredentialIsQuotaLimitedNotAReLoginPrompt() async {
    // given — the credential source is in its mandated cooldown after a throttling token-endpoint
    // response, so authorization throws a typed throttle before any request is encoded

    // when
    let outcome = await runCredentialFailure(.throttled(retryAfter: .seconds(12)))

    // then — a healthy credential in cooldown surfaces as quota, carrying the bounded wait, and is
    // never told to re-login; nothing reached the wire, so it is notStarted
    #expect(failureCause(outcome) == .quotaLimited(retryAfterSeconds: 12))
    #expect(accounting(outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func aTransientCredentialOutageIsRetryableNotAReLoginPrompt() async {
    // given — the refresh flight could not complete for a reason that may not recur

    // when
    let outcome = await runCredentialFailure(
      .temporarilyUnavailable(retryAfter: .seconds(5), detail: "the refresh did not complete")
    )

    // then — a transient outage of an intact credential is retryable, not a login failure
    guard case .retryable = failureCause(outcome) else {
      Issue.record(
        "expected a retryable transient cause, got \(String(describing: failureCause(outcome)))"
      )
      return
    }
    #expect(accounting(outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func aDeadCredentialStillRequestsReLogin() async {
    // given — the stored credential is finished and only a new login repairs it

    // when
    let outcome = await runCredentialFailure(.authenticationRequired)

    // then — the one condition that genuinely needs a login keeps the terminal prompt
    #expect(failureCause(outcome) == .authenticationRequired)
    #expect(accounting(outcome) == .notStarted)
  }
}

// MARK: - Assertions

private func requireCompleted(_ outcome: LLMStreamTermination) throws -> ChatResponse {
  guard case .completed(let response) = outcome else {
    Issue.record("expected a completed outcome, got \(outcome)")
    throw CancellationError()
  }
  return response
}

private func failureCause(_ outcome: LLMStreamTermination) -> ProviderError? {
  guard case .failed(let failure) = outcome else {
    return nil
  }
  return failure.cause
}

/// Whether a failure was accounted conservatively and carried the generated deltas as a lower bound.
/// The exact count belongs to the accumulator's own tests; here it need only prove the tokens the
/// stream produced before it broke were not silently written off.
private func isConservative(_ accounting: ProviderFailureAccounting?) -> Bool {
  guard case .mayHaveStarted(let observed) = accounting else {
    return false
  }
  return observed > 0
}

private func accounting(_ outcome: LLMStreamTermination) -> ProviderFailureAccounting? {
  switch outcome {
  case .failed(let failure):
    return failure.accounting
  case .cancelled(let disposition):
    return disposition
  case .completed:
    return nil
  }
}

/// Runs the engine against a credential source that throws `error` before any request is encoded, so
/// the outcome is purely how the engine maps that credential failure.
private func runCredentialFailure(_ error: ChatGPTCredentialError) async -> LLMStreamTermination {
  let profileID = fixedUUID("00000000-0000-0000-0000-0000000000AA")
  let identity = ChatGPTReplayIdentity(
    profileID: profileID,
    wireModel: "gpt-5",
    epoch: fixedUUID("11111111-1111-1111-1111-111111111111")
  )
  let engine = ChatGPTResponsesAttemptEngine(
    credentials: ThrowingCredentialSource(error),
    http: ScriptedHTTPExecutor([]),
    clock: ScriptedClock { _ in },
    jitter: { $0 },
    retryBudget: 3,
    requestTimeoutSeconds: 30
  )
  let plan = ChatGPTResponsesAttemptPlan(
    codec: ChatGPTProviderStateCodec(),
    identity: identity,
    profileID: profileID,
    wireModel: "gpt-5",
    encodeRequest: { _, _, _ in
      Issue.record("no request should be encoded when authorization fails")
      throw CancellationError()
    }
  )
  return await engine.run(plan: plan) { _ in }
}

// MARK: - Harness

/// Wires the engine to a scripted transport, a recording credential source, and a manual clock, so a
/// test states an HTTP script and reads back attempt counts, credential rejections, honored delays,
/// and emitted deltas.
private struct Harness: Sendable {
  let credentials: GenerationRecordingCredentialSource
  let normalIdentity: ChatGPTReplayIdentity
  let recoveryIdentity: ChatGPTReplayIdentity

  private let engine: ChatGPTResponsesAttemptEngine
  private let http: ScriptedHTTPExecutor
  private let sleeps: SleepRecorder
  private let plan: ChatGPTResponsesAttemptPlan
  private let sink: DeltaSink

  init(
    steps: [ScriptedHTTPExecutor.Step],
    retryBudget: Int = 3,
    requestTimeoutSeconds: Int = 30,
    cancelDuringSleep: Bool = false,
    failOnFirstDelta: (any Error)? = nil
  ) {
    let profileID = fixedUUID("00000000-0000-0000-0000-0000000000AA")
    let wireModel = "gpt-5"
    let normalEpoch = fixedUUID("11111111-1111-1111-1111-111111111111")
    let recoveryEpoch = fixedUUID("22222222-2222-2222-2222-222222222222")

    let codec = ChatGPTProviderStateCodec(newEpoch: { recoveryEpoch })
    self.normalIdentity = ChatGPTReplayIdentity(
      profileID: profileID,
      wireModel: wireModel,
      epoch: normalEpoch
    )
    self.recoveryIdentity = ChatGPTReplayIdentity(
      profileID: profileID,
      wireModel: wireModel,
      epoch: recoveryEpoch
    )

    let credentials = GenerationRecordingCredentialSource()
    self.credentials = credentials
    let http = ScriptedHTTPExecutor(steps)
    self.http = http
    let sleeps = SleepRecorder()
    self.sleeps = sleeps
    self.sink = DeltaSink(failOnFirstDelta: failOnFirstDelta)

    let stateLog = StateLog()
    self.plan = ChatGPTResponsesAttemptPlan(
      codec: codec,
      identity: normalIdentity,
      profileID: profileID,
      wireModel: wireModel,
      encodeRequest: { authorization, includePriorState, beginHandoff in
        stateLog.record(includePriorState)
        return HTTPRequest(
          method: .post,
          url: "https://chatgpt.test/responses",
          headers: authorization.headers,
          body: Data("{}".utf8),
          timeoutSeconds: requestTimeoutSeconds,
          responseBodyPolicy: .streaming(
            maximumUnreadBytes: HTTPResponseBodyPolicy.maximumUnreadStreamBytes,
            errorBytes: HTTPResponseBodyPolicy.diagnosticBodyBytes
          ),
          beginHandoff: beginHandoff
        )
      }
    )
    self.stateLog = stateLog

    let clock = ScriptedClock { delay in
      if cancelDuringSleep {
        throw CancellationError()
      }
      await sleeps.record(delay / .seconds(1))
    }
    self.engine = ChatGPTResponsesAttemptEngine(
      credentials: credentials,
      http: http,
      clock: clock,
      jitter: { $0 },
      retryBudget: retryBudget,
      requestTimeoutSeconds: requestTimeoutSeconds
    )
  }

  private let stateLog: StateLog

  func run() async -> LLMStreamTermination {
    await engine.run(plan: plan) { text in
      try await sink.emit(text)
    }
  }

  var attemptCount: Int {
    get async { await http.recorded.count }
  }

  var deltas: [String] {
    get async { await sink.received }
  }

  var delays: [Double] {
    get async { await sleeps.delays }
  }

  var includePriorStateLog: [Bool] {
    stateLog.values
  }
}

// MARK: - Test doubles

/// Records the credential-generation rejections the engine issues, and rotates the live generation on
/// a refresh the way a refreshable source does, so a stale-generation reject cannot rotate twice.
private actor GenerationRecordingCredentialSource: LLMCredentialSource {
  struct Rejection: Sendable, Equatable {
    let generation: LLMCredentialGeneration
    let disposition: LLMCredentialRejection
  }

  private var generationValue: UInt64 = 1
  private(set) var rejections: [Rejection] = []

  func authorization() async throws -> LLMRequestAuthorization {
    LLMRequestAuthorization(
      headers: ["Authorization": "Bearer secret-token"],
      redactionValues: ["secret-token"],
      generation: LLMCredentialGeneration(value: generationValue)
    )
  }

  func reject(generation: LLMCredentialGeneration, disposition: LLMCredentialRejection) async {
    rejections.append(Rejection(generation: generation, disposition: disposition))
    if disposition == .refresh, generation.value == generationValue {
      generationValue += 1
    }
  }

  func shutdown() async throws {}
}

/// A credential source whose `authorization()` always throws a fixed typed credential error, so a
/// test can prove how the engine maps each `ChatGPTCredentialError` case without a wire script.
private struct ThrowingCredentialSource: LLMCredentialSource {
  private let error: ChatGPTCredentialError

  init(_ error: ChatGPTCredentialError) {
    self.error = error
  }

  func authorization() async throws -> LLMRequestAuthorization {
    throw error
  }

  func reject(generation: LLMCredentialGeneration, disposition: LLMCredentialRejection) async {}

  func shutdown() async throws {}
}

/// The delta destination both engine paths write through. It can refuse the first delta to model a
/// consumer that cancels mid-stream.
private actor DeltaSink {
  private(set) var received: [String] = []
  private var firstFailure: (any Error)?

  init(failOnFirstDelta: (any Error)?) {
    self.firstFailure = failOnFirstDelta
  }

  func emit(_ text: String) throws {
    if let failure = firstFailure {
      firstFailure = nil
      throw failure
    }
    received.append(text)
  }
}

/// Records whether each encoded attempt carried prior replay state.
private final class StateLog: Sendable {
  private let states = Mutex<[Bool]>([])

  func record(_ includePriorState: Bool) {
    states.withLock { current in
      current.append(includePriorState)
    }
  }

  var values: [Bool] {
    states.withLock { current in
      current
    }
  }
}

// MARK: - Fixtures

/// A fixed, known-valid UUID string. Fails loudly rather than force-unwrapping a literal the test
/// author controls, so a typo in the vector reads as a build-time preconditions failure.
private func fixedUUID(_ value: String) -> UUID {
  guard let parsed = UUID(uuidString: value) else {
    preconditionFailure("invalid fixed UUID \(value)")
  }
  return parsed
}

private let okHead = HTTPStreamHead(statusCode: 200, headers: [:])

private func head(_ status: Int, retryAfter: Int? = nil) -> HTTPStreamHead {
  var headers: [String: String] = [:]
  if let retryAfter {
    headers["Retry-After"] = String(retryAfter)
  }
  return HTTPStreamHead(statusCode: status, headers: headers)
}

private enum Fixtures {
  static func event(_ json: String) -> Data {
    Data("data: \(json)\n\n".utf8)
  }

  /// A minimal but complete Responses stream: an announced message item, one visible delta, its done
  /// item, and a completed terminal with usage.
  static func successChunks() -> [Data] {
    [
      event(
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
      ),
      event(#"{"type":"response.output_text.delta","output_index":0,"delta":"hi"}"#),
      event(
        #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"hi"}]}}"#
      ),
      event(
        #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}}"#
      ),
    ]
  }

  /// A stream that announces an item and emits a delta but never states an outcome.
  static func partialDataChunks() -> [Data] {
    [
      event(
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
      ),
      event(#"{"type":"response.output_text.delta","output_index":0,"delta":"hi"}"#),
    ]
  }

  /// A stream that emits a data byte and then an in-band error event.
  static func dataThenErrorChunks(code: String) -> [Data] {
    [
      event(
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
      ),
      event(#"{"type":"response.output_text.delta","output_index":0,"delta":"hi"}"#),
      event(#"{"type":"error","error":{"code":"\#(code)","message":"poisoned"}}"#),
    ]
  }

  /// A non-success diagnostic body, carrying an optional error code.
  static func errorChunks(code: String? = nil, message: String) -> [Data] {
    let codeField = code.map { "\"code\":\"\($0)\"," } ?? ""
    return [Data(#"{"error":{\#(codeField)"message":"\#(message)"}}"#.utf8)]
  }
}
