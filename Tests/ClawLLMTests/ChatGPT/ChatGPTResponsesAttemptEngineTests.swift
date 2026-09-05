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
    let harness = Harness(steps: [.stream(okHead, Fixtures.basicSuccess())])

    // when
    let outcome = await harness.run()

    // then — exactly one wire attempt, the delta reaches the sink, and the reply is stamped normally
    #expect(await harness.attemptCount == 1)
    #expect(await harness.deltas == ["Hello"])
    let response = try requireCompleted(outcome)
    #expect(response.content == "Hello")
    #expect(response.providerState?.issuer == harness.normalIdentity.issuer)
  }

  // MARK: - 401 sequence

  @Test(.timeLimit(.minutes(1)))
  func aClean401RefreshesWithTheRequestGenerationThenRetriesOnce() async throws {
    // given — the first attempt's head is a clean 401, the retry succeeds
    let harness = Harness(
      steps: [
        .stream(Support.head(401), Fixtures.errorBody("expired")),
        .stream(okHead, Fixtures.basicSuccess()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — one refresh rejection carrying the first request's generation, then a second attempt
    #expect(await harness.attemptCount == 2)
    let rejections = await harness.credentialRejections
    #expect(rejections == [.init(generation: .init(value: 1), disposition: .refresh)])
    _ = try requireCompleted(outcome)
  }

  @Test(.timeLimit(.minutes(1)))
  func aSecondClean401LatchesAuthenticationRequired() async throws {
    // given — both attempts answer with a clean 401
    let harness = Harness(
      steps: [
        .stream(Support.head(401), Fixtures.errorBody("expired")),
        .stream(Support.head(401), Fixtures.errorBody("still expired")),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — refresh on the first generation, then a terminal latch on the second
    #expect(await harness.attemptCount == 2)
    let rejections = await harness.credentialRejections
    #expect(
      rejections == [
        .init(generation: .init(value: 1), disposition: .refresh),
        .init(generation: .init(value: 2), disposition: .authenticationRequired),
      ]
    )
    #expect(failureCause(outcome) == .authenticationRequired)
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func clean401SettlesRefreshForLaterWithoutSecondInference() async throws {
    // given — a real credential source can rotate successfully after the only Responses attempt
    let store = RecordingLLMCredentialStore()
    let oauth = ScriptedChatGPTOAuthRefresh([.success(refreshedCredentialPair())])
    let credentials = makeManagedCredentialSource(store: store, oauth: oauth)
    let harness = Harness(
      steps: [.stream(Support.head(401), Fixtures.errorBody("expired"))],
      retryBudget: 1,
      credentialSource: credentials
    )

    // when
    let outcome = await harness.run()

    // then — refresh completes and both the rejection marker and rotation are durable before the
    // nonreplaceable terminal returns; no second Responses inference spends the rotated credential
    #expect(await harness.attemptCount == 1)
    #expect(await oauth.callCount == 1)
    #expect(store.saveAttempts == 2)
    #expect(store.saved.first?.expiresAt == Date(timeIntervalSince1970: 0))
    #expect(failureCause(outcome) == .credentialRefreshCompleted)
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func clean401ExhaustsRefreshPolicyBeforeReplacementWithoutSecondInference() async throws {
    // given — all three attempts in the real credential policy fail transiently after one 401
    let store = RecordingLLMCredentialStore()
    let oauth = ScriptedChatGPTOAuthRefresh(
      Array(
        repeating: .failure(.transport(detail: "reset")),
        count: ChatGPTRefreshPolicy.attemptBudget
      )
    )
    let credentials = makeManagedCredentialSource(store: store, oauth: oauth)
    let harness = Harness(
      steps: [.stream(Support.head(401), Fixtures.errorBody("expired"))],
      retryBudget: 1,
      credentialSource: credentials
    )

    // when
    let outcome = await harness.run()

    // then — the source spends its whole OAuth acquisition budget before returning the typed fact;
    // the provider still issued exactly one Responses inference and persisted only the reject marker
    #expect(await oauth.callCount == ChatGPTRefreshPolicy.attemptBudget)
    #expect(await harness.attemptCount == 1)
    #expect(store.saveAttempts == 1)
    #expect(store.saved.first?.expiresAt == Date(timeIntervalSince1970: 0))
    #expect(failureCause(outcome) == .credentialRefreshExhausted)
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func aRejectedTokenMarkerFailureCannotBecomeAReplacementThatReusesTheToken() async throws {
    // given — neither the reject path nor its one publication retry can persist the expired marker
    let store = RecordingLLMCredentialStore(failing: .publicationFailed)
    let oauth = ScriptedChatGPTOAuthRefresh([.success(refreshedCredentialPair())])
    let credentials = makeManagedCredentialSource(store: store, oauth: oauth)
    let harness = Harness(
      steps: [.stream(Support.head(401), Fixtures.errorBody("expired"))],
      retryBudget: 1,
      credentialSource: credentials
    )

    // when
    let outcome = await harness.run()

    // then — no OAuth or second inference starts, and the distinct non-replaceable cause prevents a
    // new worker from loading the still-fresh rejected credential left on disk
    #expect(await harness.attemptCount == 1)
    #expect(await oauth.callCount == 0)
    #expect(store.saveAttempts == 2)
    #expect(failureCause(outcome) == .credentialStateUnavailable)
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  // MARK: - Access and quota

  @Test(.timeLimit(.minutes(1)))
  func an403IsAccessDeniedWithoutRefreshOrRetry() async throws {
    // given
    let harness = Harness(steps: [.stream(Support.head(403), Fixtures.errorBody("no route"))])

    // when
    let outcome = await harness.run()

    // then — one attempt, no credential rejection, and no re-login prompt
    #expect(await harness.attemptCount == 1)
    #expect(await harness.credentialRejections.isEmpty)
    #expect(failureCause(outcome) == .accessDenied)
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [(60, 30), (10, 10)])
  func aClean429IsQuotaLimitedHonoringTheClampedRetryAfter(
    timeout: Int,
    expectedClamp: Int
  ) async throws {
    // given — a 429 asks for 300 seconds, retried once then exhausted at budget 2
    let harness = Harness(
      steps: [
        .stream(Support.head(429, retryAfter: 300), Fixtures.errorBody("slow down")),
        .stream(Support.head(429, retryAfter: 300), Fixtures.errorBody("slow down")),
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
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func aFirst429IsTerminalWhenQuotaRetriesAreDisabled() async throws {
    // given — a fallback route exists, so retrying this subscription wall is pure waste; the budget
    // is wide enough that only the flag, not the budget, can explain a single attempt
    let harness = Harness(
      steps: [.stream(Support.head(429, retryAfter: 300), Fixtures.errorBody("slow down"))],
      retryBudget: 3,
      treatsQuotaAsTerminal: true
    )

    // when
    let outcome = await harness.run()

    // then — no backoff wait, and the clamped Retry-After hint still reaches the failure so a
    // fallback's cooldown can honor it
    #expect(await harness.attemptCount == 1)
    #expect(await harness.delays.isEmpty)
    #expect(failureCause(outcome) == .quotaLimited(retryAfterSeconds: 30))
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func a429StillRetriesWhenQuotaRetriesAreNotDisabled() async throws {
    // given — no fallback route, so retrying the wall is still the only way to recover this turn
    let harness = Harness(
      steps: [
        .stream(Support.head(429, retryAfter: 300), Fixtures.errorBody("slow down")),
        .stream(okHead, Fixtures.basicSuccess()),
      ],
      retryBudget: 3,
      treatsQuotaAsTerminal: false
    )

    // when
    let outcome = await harness.run()

    // then — the first 429 is retried after the clamped delay rather than failing immediately
    #expect(await harness.attemptCount == 2)
    #expect(await harness.delays == [30])
    _ = try requireCompleted(outcome)
  }

  // MARK: - Transient and transport retries

  @Test(.timeLimit(.minutes(1)))
  func a408RetriesWithBoundedBackoffThenSucceeds() async throws {
    // given
    let harness = Harness(
      steps: [
        .stream(Support.head(408), Fixtures.errorBody("timeout")),
        .stream(okHead, Fixtures.basicSuccess()),
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
        .stream(Support.head(500), Fixtures.errorBody("boom")),
        .stream(Support.head(500), Fixtures.errorBody("boom")),
      ],
      retryBudget: 2
    )

    // when
    let outcome = await harness.run()

    // then
    #expect(await harness.attemptCount == 2)
    #expect(failureCause(outcome) == .retryable(status: 500, message: "boom"))
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func aDefinitelyNotSentTransportFailureRetries() async throws {
    // given — nothing could have been written, so the attempt is replayable
    let harness = Harness(
      steps: [
        .transportFailure(
          HTTPTransportFailure(disposition: .definitelyNotSent, safeMessage: "refused")
        ),
        .stream(okHead, Fixtures.basicSuccess()),
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
    let token = GenerationRecordingCredentialSource.accessToken
    let harness = Harness(
      steps: [
        .transportFailure(
          HTTPTransportFailure(
            disposition: .mayHaveBeenSent,
            safeMessage: "dropped \(token)"
          )
        ),
        .stream(okHead, Fixtures.basicSuccess()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — a single attempt, conservative accounting, and no second dispatch of the success step
    #expect(await harness.attemptCount == 1)
    #expect(await harness.delays.isEmpty)
    let failure = try #require(failureCause(outcome))
    #expect(
      failure
        == .transportFailure(message: "dropped \(SecretRedactor.replacement)")
    )
    #expect(Support.message(of: failure)?.contains(token) == false)
    #expect(Support.accounting(of: outcome) == .mayHaveStarted(observedCompletionTokens: 0))
  }

  // MARK: - One shared budget

  @Test(.timeLimit(.minutes(1)))
  func oneBudgetCountsEveryRetryClassAcrossTheWholeCall() async throws {
    // given — three different retry classes, then a success the budget must never reach
    let harness = Harness(
      steps: [
        .stream(Support.head(401), Fixtures.errorBody("expired")),
        .stream(Support.head(500), Fixtures.errorBody("boom")),
        .transportFailure(
          HTTPTransportFailure(disposition: .definitelyNotSent, safeMessage: "refused")
        ),
        .stream(okHead, Fixtures.basicSuccess()),
      ],
      retryBudget: 3
    )

    // when
    let outcome = await harness.run()

    // then — a budget that reset between classes would reach the 4th step and complete; a shared one
    // stops at three wire attempts and fails
    #expect(await harness.attemptCount == 3)
    #expect(failureCause(outcome) == .connectFailed(message: "refused"))
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func strictTerminalValidationAcceptsRestatingAliasesThroughStreamEnd() async throws {
    // given — the first terminal omits its model and a later alias supplies it in a separate chunk.
    // Production does not wait for that alias; strict evaluation must retain and reconcile it.
    let body =
      Fixtures.basicSuccess() + [
        Fixtures.event(
          #"{"type":"response.done","response":{"id":"resp_1","status":"completed","model":"gpt-5.6-sol"}}"#
        )
      ]
    let harness = Harness(
      steps: [.stream(okHead, body)],
      terminalValidationPolicy: .throughStreamEnd
    )

    // when
    let outcome = await harness.run()

    // then — returning the first terminal immediately would lose the authoritative model alias;
    // treating strict EOF as ambiguous would fail instead of completing.
    #expect(await harness.attemptCount == 1)
    let response = try requireCompleted(outcome)
    #expect(response.content == "Hello")
    #expect(response.reportedModel == "gpt-5.6-sol")
  }

  @Test(.timeLimit(.minutes(1)))
  func strictTerminalValidationRejectsAConflictingAliasInALaterChunk() async throws {
    // given — the production default may finish on the first terminal, but an evaluation must drain
    // the stream and reconcile a later alias even when the transport delivers it separately.
    let body =
      Array(Fixtures.basicSuccess().dropLast()) + [
        Fixtures.completedTerminal(),
        Fixtures.event(
          #"{"type":"response.done","response":{"id":"resp_1","status":"completed","model":"gpt-5.6-sol"}}"#
        ),
        Fixtures.event(
          #"{"type":"response.done","response":{"id":"resp_1","status":"completed","model":"different-model"}}"#
        ),
      ]
    let harness = Harness(
      steps: [.stream(okHead, body)],
      terminalValidationPolicy: .throughStreamEnd
    )

    // when
    let outcome = await harness.run()

    // then — stopping at the first chunk would incorrectly return a completed response.
    #expect(await harness.attemptCount == 1)
    #expect(failureCause(outcome) == .modelIdentityMismatch)
  }

  // MARK: - Invalid encrypted content recovery

  @Test(.timeLimit(.minutes(1)))
  func aCleanInvalidEncryptedContentRetriesOnceStateFreeInANewEpoch() async throws {
    // given — a clean head rejection naming poisoned replay state, then a success
    let harness = Harness(
      steps: [
        .stream(
          Support.head(400),
          Fixtures.errorBody("bad state", code: "invalid_encrypted_content")
        ),
        .stream(okHead, Fixtures.basicSuccess()),
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
          Support.head(400),
          Fixtures.errorBody("bad state", code: "invalid_encrypted_content")
        ),
        .stream(Support.head(500), Fixtures.errorBody("boom")),
      ],
      retryBudget: 2
    )

    // when
    let outcome = await harness.run()

    // then — the recovery consumed one attempt, so the 500 exhausts the budget rather than retrying
    #expect(await harness.attemptCount == 2)
    #expect(failureCause(outcome) == .retryable(status: 500, message: "boom"))
  }

  // MARK: - Vision refusal

  /// A refusal that names the rejected content part in `param` and the error class in `type`, while
  /// its `message` mentions neither. Only the raw body carries the markers, so a classification that
  /// read the sanitized diagnostic instead would miss this — which is the regression this fixture
  /// exists to catch.
  private static let visionRefusalBody = Data(
    """
    {"error":{"type":"invalid_request_error","param":"input[1].content[0].input_image",\
    "code":null,"message":"This model does not support image inputs."}}
    """.utf8
  )

  @Test(.timeLimit(.minutes(1)))
  func aVisionRefusalIsNamedRatherThanLeftAsAGenericRejection() async throws {
    // given — a clean 400 refusing the request because the model cannot see
    let harness = Harness(steps: [.stream(Support.head(400), [Self.visionRefusalBody])])

    // when
    let outcome = await harness.run()

    // then — the refusal is recognised from the raw body, ahead of the poisoned-state check, and
    // reduced to the text-free cause the owner reply names. It is never retried: it would refuse
    // identically, and the server generated nothing.
    #expect(failureCause(outcome) == .visionUnsupported)
    #expect(await harness.attemptCount == 1)
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func aBadRequestWithoutAnImagePartStaysTheGenericRejection() async throws {
    // given — the same status and error class, with no image content part named anywhere
    let body = Data(
      """
      {"error":{"type":"invalid_request_error","param":"temperature","code":null,\
      "message":"Unsupported value for temperature."}}
      """.utf8
    )
    let harness = Harness(steps: [.stream(Support.head(400), [body])])

    // when
    let outcome = await harness.run()

    // then — the discriminator is additive; an unrelated rejection keeps its diagnostic
    #expect(
      failureCause(outcome) == .terminal(status: 400, message: "Unsupported value for temperature.")
    )
  }

  // MARK: - The retry boundary

  @Test(.timeLimit(.minutes(1)))
  func aFailureAfterTheFirstDataByteIsNeverReplayed() async throws {
    // given — a 2xx stream that emits a data event and then drops the connection
    let token = GenerationRecordingCredentialSource.accessToken
    let harness = Harness(
      steps: [
        .streamFailure(
          okHead,
          Fixtures.slowSuccess(),
          ScriptedTransportFailure(message: "dropped mid-stream \(token)")
        ),
        .stream(okHead, Fixtures.basicSuccess()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — the boundary closed on the first data byte, so the drop is not retried, and the
    // generated deltas are carried as a conservative lower bound
    #expect(await harness.attemptCount == 1)
    let failure = try #require(failureCause(outcome))
    #expect(
      failure
        == .transportFailure(message: "dropped mid-stream \(SecretRedactor.replacement)")
    )
    #expect(Support.message(of: failure)?.contains(token) == false)
    #expect(Support.isConservative(Support.accounting(of: outcome)))
  }

  @Test(.timeLimit(.minutes(1)))
  func anInvalidEncryptedContentAfterDataDoesNotTriggerRecovery() async throws {
    // given — the poisoned-state error arrives in-band, after a data byte has streamed
    let harness = Harness(
      steps: [
        .stream(okHead, Fixtures.dataThenError(code: "invalid_encrypted_content")),
        .stream(okHead, Fixtures.basicSuccess()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then — no state-free recovery once the boundary has closed; degrade conservatively instead
    #expect(await harness.attemptCount == 1)
    #expect(harness.includePriorStateLog == [true])
    #expect(Support.isConservative(Support.accounting(of: outcome)))
  }

  @Test(.timeLimit(.minutes(1)))
  func aTerminalFreeStreamEOFIsConservativeAndNotRetried() async throws {
    // given — a 2xx stream that ends without ever stating an outcome
    let harness = Harness(
      steps: [
        .stream(okHead, Fixtures.slowSuccess()),
        .stream(okHead, Fixtures.basicSuccess()),
      ]
    )

    // when
    let outcome = await harness.run()

    // then
    #expect(await harness.attemptCount == 1)
    #expect(failureCause(outcome) == .partialStreamWithoutCompletedTerminal)
    #expect(Support.isConservative(Support.accounting(of: outcome)))
  }

  // MARK: - Cancellation

  @Test(.timeLimit(.minutes(1)))
  func cancellationBeforeAuthorizationIsNotStarted() async {
    // given
    let harness = Harness(steps: [.stream(okHead, Fixtures.basicSuccess())])

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
      steps: [.stream(Support.head(500), Fixtures.errorBody("boom"))],
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
      steps: [.stream(okHead, Fixtures.basicSuccess())],
      failOnFirstDelta: CancellationError()
    )

    // when
    let outcome = await harness.run()

    // then — the model may have been asked, so cancellation retains the observed completion debit
    if case .cancelled(let disposition) = outcome {
      #expect(disposition == .mayHaveStarted(observedCompletionTokens: 3))
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
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func aTransientCredentialOutageIsTypedRefreshExhaustionNotAReLoginPrompt() async {
    // given — the refresh flight could not complete for a reason that may not recur

    // when
    let outcome = await runCredentialFailure(
      .temporarilyUnavailable(retryAfter: .seconds(5), detail: "the refresh did not complete")
    )

    // then — a transient outage of an intact credential is explicitly replacement-eligible, not a
    // generic inference retry or login failure
    guard case .credentialRefreshExhausted = failureCause(outcome) else {
      Issue.record(
        "expected credential refresh exhaustion, got \(String(describing: failureCause(outcome)))"
      )
      return
    }
    #expect(Support.accounting(of: outcome) == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func aDeadCredentialStillRequestsReLogin() async {
    // given — the stored credential is finished and only a new login repairs it

    // when
    let outcome = await runCredentialFailure(.authenticationRequired)

    // then — the one condition that genuinely needs a login keeps the terminal prompt
    #expect(failureCause(outcome) == .authenticationRequired)
    #expect(Support.accounting(of: outcome) == .notStarted)
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

/// Runs the engine against a credential source that throws `error` before any request is encoded, so
/// the outcome is purely how the engine maps that credential failure.
private func runCredentialFailure(_ error: ChatGPTCredentialError) async -> LLMStreamTermination {
  let profileID = Support.fixedUUID("00000000-0000-0000-0000-0000000000AA")
  let identity = ChatGPTReplayIdentity(
    profileID: profileID,
    wireModel: "gpt-5",
    epoch: Support.fixedUUID("11111111-1111-1111-1111-111111111111")
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
    outputScope: nil,
    terminalValidationPolicy: .firstTerminal,
    encodeRequest: { _, _, _ in
      Issue.record("no request should be encoded when authorization fails")
      throw CancellationError()
    }
  )
  return await engine.run(plan: plan) { _ in }
}

private func refreshedCredentialPair() -> ChatGPTTokenPair {
  ChatGPTTokenPair(
    accessToken: "rotated-access-token",
    refreshToken: "rotated-refresh-token",
    expiresAt: Date().addingTimeInterval(3_600)
  )
}

private func makeManagedCredentialSource(
  store: RecordingLLMCredentialStore,
  oauth: ScriptedChatGPTOAuthRefresh
) -> ChatGPTCredentialSource<ScriptedClock> {
  ChatGPTCredentialSource(
    initialCredential: storedCredential(),
    store: store,
    oauth: oauth,
    clock: ScriptedClock { _ in },
    wallDate: Date.init
  )
}

// MARK: - Harness

/// Wires the engine to a scripted transport, a recording credential source, and a manual clock, so a
/// test states an HTTP script and reads back attempt counts, credential rejections, honored delays,
/// and emitted deltas.
private struct Harness: Sendable {
  let normalIdentity: ChatGPTReplayIdentity
  let recoveryIdentity: ChatGPTReplayIdentity

  private let recordingCredentials: GenerationRecordingCredentialSource?
  private let engine: ChatGPTResponsesAttemptEngine
  private let http: ScriptedHTTPExecutor
  private let sleeps: SleepRecorder
  private let plan: ChatGPTResponsesAttemptPlan
  private let sink: DeltaSink

  init(
    steps: [ScriptedHTTPExecutor.Step],
    retryBudget: Int = 3,
    requestTimeoutSeconds: Int = 30,
    treatsQuotaAsTerminal: Bool = false,
    terminalValidationPolicy: StreamingTerminalValidationPolicy = .firstTerminal,
    cancelDuringSleep: Bool = false,
    failOnFirstDelta: (any Error)? = nil,
    credentialSource: (any LLMCredentialSource)? = nil
  ) {
    let profileID = Support.fixedUUID("00000000-0000-0000-0000-0000000000AA")
    let wireModel = "gpt-5"
    let normalEpoch = Support.fixedUUID("11111111-1111-1111-1111-111111111111")
    let recoveryEpoch = Support.fixedUUID("22222222-2222-2222-2222-222222222222")

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

    let resolvedCredentials: any LLMCredentialSource
    if let credentialSource {
      recordingCredentials = nil
      resolvedCredentials = credentialSource
    } else {
      let credentials = GenerationRecordingCredentialSource()
      recordingCredentials = credentials
      resolvedCredentials = credentials
    }
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
      outputScope: nil,
      terminalValidationPolicy: terminalValidationPolicy,
      encodeRequest: { authorization, includePriorState, beginHandoff in
        stateLog.record(includePriorState)
        return HTTPRequest(
          method: .post,
          url: "https://chatgpt.test/responses",
          headers: authorization.headers,
          body: Data("{}".utf8),
          timeout: .seconds(requestTimeoutSeconds),
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
      credentials: resolvedCredentials,
      http: http,
      clock: clock,
      jitter: { $0 },
      retryBudget: retryBudget,
      requestTimeoutSeconds: requestTimeoutSeconds,
      treatsQuotaAsTerminal: treatsQuotaAsTerminal
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

  var credentialRejections: [GenerationRecordingCredentialSource.Rejection] {
    get async {
      guard let recordingCredentials else {
        return []
      }
      return await recordingCredentials.rejections
    }
  }
}

// MARK: - Test doubles

/// Records the credential-generation rejections the engine issues, and rotates the live generation on
/// a refresh the way a refreshable source does, so a stale-generation reject cannot rotate twice.
private actor GenerationRecordingCredentialSource: LLMCredentialSource {
  static let accessToken = "secret-token"

  struct Rejection: Sendable, Equatable {
    let generation: LLMCredentialGeneration
    let disposition: LLMCredentialRejection
  }

  private var generationValue: UInt64 = 1
  private(set) var rejections: [Rejection] = []

  func authorization() async throws -> LLMRequestAuthorization {
    LLMRequestAuthorization(
      headers: ["Authorization": "Bearer \(Self.accessToken)"],
      redactionValues: [Self.accessToken],
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

// MARK: - Shared support

private typealias Support = ChatGPTProviderTestSupport
private typealias Fixtures = Support.Fixtures

private let okHead = Support.okHead
