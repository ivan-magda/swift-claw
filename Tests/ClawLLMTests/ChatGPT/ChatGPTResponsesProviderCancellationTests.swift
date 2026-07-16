import ClawAuth
import ClawCore
import ClawTestSupport
import Foundation
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

// MARK: - Shared support

private typealias Support = ChatGPTProviderTestSupport
private typealias ProviderHarness = Support.Harness
private typealias Fixtures = Support.Fixtures

private let okHead = Support.okHead
private let plainRequest = Support.plainRequest
