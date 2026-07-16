import ClawAuth
import ClawCore
import ClawTestSupport
import Foundation
import Logging
import Synchronization
import Testing

@testable import ClawLLM

/// The owning-session races the provider inherits from `LLMEventStream`: `stream` returns
/// synchronously, cancellation before the handoff owes no debit, consumer abandonment is
/// conservative, a committed completion wins a later cancellation, and repeated joins agree. Every
/// wait is a manual gate or a scripted clock, so nothing here races real time.
@Suite struct ChatGPTResponsesProviderCancellationTests {
  @Test(.timeLimit(.minutes(1)))
  func cancellationBeforeAuthorizationOwesNoDebitAndDispatchesNothing() async {
    // given — authorization parks on a gate, so cancellation lands before any handoff
    let gate = AsyncGate()
    let harness = ProviderHarness(
      steps: [.stream(okHead, Fixtures.basicSuccess())],
      credentials: GatedCredentialSource(gate: gate)
    )

    // when — the returned handle is cancelled before the credential ever resolves
    let stream = harness.provider.stream(request: plainRequest)
    stream.cancel()
    gate.open()
    let terminal = await stream.awaitTermination()

    // then — no wire attempt, and the outcome owes nothing
    #expect(terminal == .cancelled(.notStarted))
    #expect(await harness.http.recorded.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func streamReturnsSynchronouslyBeforeTheProducerCanFinish() async {
    // given — the transport is held open behind a gate, so the producer cannot have finished when
    // `stream` returns
    let gate = AsyncGate()
    let harness = ProviderHarness(
      steps: [.blockedStream(okHead, Fixtures.basicSuccess(), gate)]
    )

    // when
    let stream = harness.provider.stream(request: plainRequest)
    defer { gate.open() }

    // then — the handle exists and is joinable before the held-open transfer could have completed
    let cancelled = await stream.cancelAndAwait()
    if case .completed = cancelled {
      Issue.record("a held-open transfer should not have completed before cancellation")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func abandoningTheIteratorMidStreamIsConservative() async {
    // given — a stream that publishes a delta the consumer then walks away from
    let harness = ProviderHarness(steps: [.stream(okHead, Fixtures.slowSuccess())])

    // when — the consumer breaks after the first delta, dropping the iterator
    let stream = harness.provider.stream(request: plainRequest)
    var iterator = stream.makeAsyncIterator()
    _ = try? await iterator.next()

    // then — whether the abandonment lease stopped the work first or the finite body reached its
    // ambiguous end first, the tokens the stream produced are never silently written off: the
    // accounting stays conservative rather than resetting to notStarted
    let terminal = await stream.awaitTermination()
    #expect(isConservative(accounting(of: terminal)))
  }

  @Test(.timeLimit(.minutes(1)))
  func aCommittedCompletionWinsALaterCancellation() async {
    // given — a clean success
    let harness = ProviderHarness(steps: [.stream(okHead, Fixtures.basicSuccess())])

    // when — the terminal is joined first, then a cancellation arrives after the commit
    let stream = harness.provider.stream(request: plainRequest)
    let joined = await stream.awaitTermination()
    let afterCancel = await stream.cancelAndAwait()

    // then — the cached completion is the only outcome, unchanged by the late cancellation
    #expect(joined == afterCancel)
    guard case .completed(let response) = joined else {
      Issue.record("expected a completed outcome, got \(joined)")
      return
    }
    #expect(response.content == "Hello")
  }

  @Test(.timeLimit(.minutes(1)))
  func repeatedJoinsReturnTheSameCachedOutcome() async {
    // given
    let harness = ProviderHarness(steps: [.stream(okHead, Fixtures.basicSuccess())])

    // when — the same stream is joined twice
    let stream = harness.provider.stream(request: plainRequest)
    let first = await stream.awaitTermination()
    let second = await stream.awaitTermination()

    // then
    #expect(first == second)
  }
}

// MARK: - Test doubles

/// A credential source whose authorization parks on a gate until cancelled, so a test can land a
/// cancellation before the handoff without racing a real clock.
private struct GatedCredentialSource: LLMCredentialSource {
  let gate: AsyncGate

  func authorization() async throws -> LLMRequestAuthorization {
    await gate.wait()
    try Task.checkCancellation()
    return LLMRequestAuthorization(
      headers: ["Authorization": "Bearer test-token"],
      redactionValues: ["test-token"],
      generation: .zero
    )
  }

  func reject(generation: LLMCredentialGeneration, disposition: LLMCredentialRejection) async {}

  func shutdown() async throws {}
}

/// Whether an outcome was accounted conservatively — the model may have been asked, so its tokens
/// are carried rather than written off.
private func isConservative(_ accounting: ProviderFailureAccounting?) -> Bool {
  guard case .mayHaveStarted(let observed) = accounting else {
    return false
  }
  return observed > 0
}

private func accounting(of terminal: LLMStreamTermination) -> ProviderFailureAccounting? {
  switch terminal {
  case .failed(let failure):
    return failure.accounting
  case .cancelled(let disposition):
    return disposition
  case .completed:
    return nil
  }
}

// MARK: - Harness

private struct ProviderHarness {
  let http: ScriptedHTTPExecutor
  let provider: ChatGPTResponsesProvider<ScriptedClock>

  init(
    steps: [ScriptedHTTPExecutor.Step],
    credentials: any LLMCredentialSource = ProviderHarness.defaultCredentials
  ) {
    let http = ScriptedHTTPExecutor(steps)
    self.http = http
    let sleeps = SleepRecorder()
    self.provider = ChatGPTResponsesProvider(
      http: http,
      credentials: credentials,
      credentialProfileID: fixedProfileID,
      buildVersion: "1.2.3-test",
      retryBudget: 3,
      requestTimeoutSeconds: 30,
      clock: ScriptedClock { delay in
        await sleeps.record(delay / .seconds(1))
      },
      jitter: { duration in duration },
      epochID: { fixedEpoch },
      logger: Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() }),
      replayDropsReporter: nil
    )
  }

  static var defaultCredentials: ScriptedLLMCredentialSource {
    ScriptedLLMCredentialSource(
      headers: ["Authorization": "Bearer test-token"],
      redactionValues: ["test-token"]
    )
  }
}

// MARK: - Fixtures

private func fixedUUID(_ value: String) -> UUID {
  guard let parsed = UUID(uuidString: value) else {
    preconditionFailure("invalid fixed UUID \(value)")
  }
  return parsed
}

private let fixedProfileID = fixedUUID("00000000-0000-0000-0000-0000000000AA")
private let fixedEpoch = fixedUUID("11111111-1111-1111-1111-111111111111")
private let okHead = HTTPStreamHead(statusCode: 200, headers: [:])

private let plainRequest = ChatRequest(
  model: "gpt-5",
  messages: [ChatMessage(role: .user, content: "hello")],
  maxOutputTokens: 256
)

private enum Fixtures {
  static func event(_ json: String) -> Data {
    Data("data: \(json)\n\n".utf8)
  }

  static func basicSuccess() -> [Data] {
    [
      event(
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
      ),
      event(#"{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}"#),
      event(
        #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#
      ),
      event(
        #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}}"#
      ),
    ]
  }

  /// Announces an item and emits a delta but never states an outcome, so a consumer that abandons
  /// the iterator mid-stream leaves a turn the model may already have begun.
  static func slowSuccess() -> [Data] {
    [
      event(
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
      ),
      event(#"{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}"#),
    ]
  }
}
