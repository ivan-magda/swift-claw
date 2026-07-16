import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

// MARK: - Fixtures

/// A response whose fields are distinct so a golden asserts literals, not just a shape.
private func racedResponse(content: String = "raced reply") -> ChatResponse {
  ChatResponse(
    content: content,
    finishReason: "stop",
    usage: ChatUsage(promptTokens: 11, completionTokens: 13, totalTokens: 24),
    costFromProvider: 0.002
  )
}

/// Fires the deadline the instant the child sleeps.
private var instantDeadlineClock: ScriptedClock {
  ScriptedClock { _ in }
}

/// Parks the deadline until the child is cancelled — the provider-wins pacing, with no real sleep and
/// no timer that can fire on its own.
private var deadlineParkedUntilCancelledClock: ScriptedClock {
  ScriptedClock { _ in
    while !Task.isCancelled {
      await Task.yield()
    }
  }
}

/// A deadline that fires only when `gate` is released, so a test can sequence "the terminal has
/// committed" strictly before "the deadline takes the lock".
private func gatedDeadlineClock(_ gate: TypingReleaseGate) -> ScriptedClock {
  ScriptedClock { _ in
    await gate.awaitRelease()
  }
}

/// Spins until this child is cancelled — the deterministic stand-in for a provider the deadline
/// cancels, with no sleep.
private func awaitCancellation() async {
  while !Task.isCancelled {
    await Task.yield()
  }
}

/// The streaming runtime's consumer, reduced to what a coordinator test needs: accumulate, claim the
/// race on the terminal, and defer everything else to the stream's own join.
private let accumulatingConsume:
  @Sendable (LLMEventStream, ProviderRaceBox) async -> StreamConsumerOutcome = { stream, box in
    var content = ""
    do {
      for try await event in stream {
        try Task.checkCancellation()
        switch event {
        case .delta(let delta):
          content += delta
        case .finished:
          _ = box.claim(.provider)
          return .completed(content)
        }
      }
      return .cut
    } catch {
      return .cut
    }
  }

/// A consumer that never reads — it parks until cancelled — so the terminal's final event stays
/// unconsumed while the deadline takes the lock.
private let neverReadingConsume:
  @Sendable (LLMEventStream, ProviderRaceBox) async -> StreamConsumerOutcome = { _, _ in
    await awaitCancellation()
    return .cut
  }

private let noAuxiliary: @Sendable (ProviderRaceBox) async -> Void = { _ in }

// MARK: - Outcome plumbing

/// Resolves an outcome once, so a test can start a coordinator, prove it has NOT returned while a
/// child is gated, then read the outcome after releasing the gate.
private actor OutcomeBox {
  private var outcome: ProviderDeadlineOutcome?
  private var waiters: [CheckedContinuation<ProviderDeadlineOutcome, Never>] = []

  func resolve(_ resolved: ProviderDeadlineOutcome) {
    guard outcome == nil else { return }
    outcome = resolved
    for waiter in waiters {
      waiter.resume(returning: resolved)
    }
    waiters.removeAll()
  }

  func value() async -> ProviderDeadlineOutcome {
    if let outcome {
      return outcome
    }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private func runOutcome(
  _ operation: @escaping @Sendable () async -> ProviderDeadlineOutcome
) -> OutcomeBox {
  let box = OutcomeBox()
  Task {
    await box.resolve(await operation())
  }
  return box
}

// MARK: - Matchers

private struct OutcomeMismatch: Error, CustomStringConvertible {
  let description: String
}

private func requireResponse(_ outcome: ProviderDeadlineOutcome) throws -> ChatResponse {
  guard case .response(let response) = outcome else {
    throw OutcomeMismatch(description: "expected .response, got \(outcome)")
  }
  return response
}

private func requireFailed(_ outcome: ProviderDeadlineOutcome) throws -> any Error {
  guard case .failed(let error) = outcome else {
    throw OutcomeMismatch(description: "expected .failed, got \(outcome)")
  }
  return error
}

private func requireTimedOut(
  _ outcome: ProviderDeadlineOutcome
) throws -> ProviderDeadlineAccounting {
  guard case .timedOut(let accounting) = outcome else {
    throw OutcomeMismatch(description: "expected .timedOut, got \(outcome)")
  }
  return accounting
}

// MARK: - Cancellation-aware send double

/// A send that blocks until released OR cancelled — the ephemeral-send analog of a production HTTP
/// POST, so the bounded-send drain can abandon it without wedging on a sink that ignores cancellation.
private actor GatedSend {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var finished = false
  private(set) var started = false
  private(set) var observedCancellation = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func run() async {
    started = true
    for waiter in startWaiters {
      waiter.resume()
    }
    startWaiters.removeAll()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if finished {
          continuation.resume()
        } else {
          waiters.append(continuation)
        }
      }
    } onCancel: {
      Task { await self.markCancelled() }
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    finished = true
    resumeAll()
  }

  private func markCancelled() {
    observedCancellation = true
    finished = true
    resumeAll()
  }

  private func resumeAll() {
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
  }
}

// One @Suite of deadline-coordinator behaviors sharing the fixtures above.
@Suite struct ProviderDeadlineCoordinatorTests {
  // MARK: - Buffered race

  @Test func providerSuccessBeforeTheDeadlineReturnsTheResponse() async throws {
    // given — the deadline parks until cancelled, so the provider wins outright
    let expected = racedResponse(content: "won")

    // when
    let outcome = await ProviderDeadlineCoordinator.raceBuffered(
      deadlineSeconds: 180,
      clock: deadlineParkedUntilCancelledClock,
      call: {
        .response(expected)
      }
    )

    // then
    let response = try requireResponse(outcome)
    #expect(response == expected)
  }

  @Test func providerFailureBeforeTheDeadlineSurfacesTheFailure() async throws {
    // given
    let failure = ProviderError.terminal(status: 400, message: "bad request")

    // when
    let outcome = await ProviderDeadlineCoordinator.raceBuffered(
      deadlineSeconds: 180,
      clock: deadlineParkedUntilCancelledClock,
      call: {
        .failed(failure)
      }
    )

    // then
    let error = try requireFailed(outcome)
    #expect(error as? ProviderError == failure)
  }

  @Test func rawCancellationUnderAWonDeadlineTimesOutNotStarted() async throws {
    // given — the deadline fires instantly; the provider, cancelled during authorization, proves it
    // never started, so the timeout is a no-debit raw cancellation
    let outcome = await ProviderDeadlineCoordinator.raceBuffered(
      deadlineSeconds: 180,
      clock: instantDeadlineClock,
      call: {
        await awaitCancellation()
        return .failed(
          ProviderFailure(
            cause: .terminal(status: nil, message: "cancelled before send"),
            accounting: .notStarted
          )
        )
      }
    )

    // then
    let accounting = try requireTimedOut(outcome)
    #expect(accounting == .notStarted)
  }

  @Test func typedCancellationUnderAWonDeadlineKeepsTheObservedCount() async throws {
    // given — the provider, cancelled after an ambiguous handoff, reports a typed inference
    // cancellation; the timeout is conservative and keeps the observed lower bound
    let outcome = await ProviderDeadlineCoordinator.raceBuffered(
      deadlineSeconds: 180,
      clock: instantDeadlineClock,
      call: {
        await awaitCancellation()
        return .failed(ProviderInferenceCancellation(observing: 7))
      }
    )

    // then
    let accounting = try requireTimedOut(outcome)
    #expect(accounting == .mayHaveStarted(observedCompletionTokens: 7))
  }

  @Test func aResponseRacingUnderAWonDeadlineSurvivesAsAuthoritativeUsage() async throws {
    // given — the deadline takes the lock first, but the provider finishes with a real response
    // anyway. The loser is drained, not discarded: the response survives for its authoritative usage,
    // while the owner-visible outcome stays a timeout.
    let expected = racedResponse(content: "landed under the deadline")

    // when
    let outcome = await ProviderDeadlineCoordinator.raceBuffered(
      deadlineSeconds: 180,
      clock: instantDeadlineClock,
      call: {
        await awaitCancellation()
        return .response(expected)
      }
    )

    // then
    let accounting = try requireTimedOut(outcome)
    #expect(accounting == .completed(expected))
  }

  @Test func aProviderWinCancelsAndDrainsTheDeadlineTimer() async throws {
    // given — a clock whose sleep records that it was cancelled, so "the timer was cancelled and
    // drained" is observable rather than inferred from the test merely finishing
    let timerCancelled = CompletionFlag()
    let recordingClock = ScriptedClock { _ in
      while !Task.isCancelled {
        await Task.yield()
      }
      await timerCancelled.markDone()
    }
    let expected = racedResponse(content: "provider first")

    // when
    let outcome = await ProviderDeadlineCoordinator.raceBuffered(
      deadlineSeconds: 180,
      clock: recordingClock,
      call: {
        .response(expected)
      }
    )

    // then — the response returns and the timer was cancelled, never left to fire its full window
    let response = try requireResponse(outcome)
    #expect(response == expected)
    #expect(await timerCancelled.done == true)
  }

  @Test(.timeLimit(.minutes(1)))
  func theCoordinatorDrainsAGatedProviderLoserBeforeReturning() async throws {
    // given — the deadline wins instantly, but the provider loser stays in flight behind a gate that
    // ignores cancellation. The coordinator must not return until that loser exits.
    let providerGate = NonCooperativeStreamGate()
    let providerExited = CompletionFlag()
    let returned = CompletionFlag()

    // when
    let box = runOutcome {
      let outcome = await ProviderDeadlineCoordinator.raceBuffered(
        deadlineSeconds: 180,
        clock: instantDeadlineClock,
        call: {
          await providerGate.markStartedAndWaitForRelease()
          await providerExited.markDone()
          return .failed(ProviderInferenceCancellation(observing: 3))
        }
      )
      await returned.markDone()
      return outcome
    }
    await providerGate.waitUntilStarted()
    // A yield lets a coordinator that returned before draining its loser surface, without a window.
    await Task.yield()
    let doneWhileProviderGated = await returned.done

    // then — the coordinator is still parked on the gated loser
    #expect(doneWhileProviderGated == false)
    await providerGate.release()
    let accounting = try requireTimedOut(await box.value())
    #expect(accounting == .mayHaveStarted(observedCompletionTokens: 3))
    #expect(await providerExited.done == true)
  }

  // MARK: - Streaming race

  @Test func aCachedTerminalUnderAWonDeadlineStillSucceeds() async throws {
    // given — a stream that commits its terminal at once, a consumer that never reads it, and a
    // deadline gated until after the commit is observable. The deadline takes the lock, yet the
    // cached completion means the response still succeeds.
    let expected = racedResponse(content: "committed then timed out")
    let stream = LLMEventStream.make { _ in
      .completed(expected)
    }
    let deadlineGate = TypingReleaseGate()

    // when
    let box = runOutcome {
      await ProviderDeadlineCoordinator.raceStreaming(
        stream: stream,
        deadlineSeconds: 180,
        clock: gatedDeadlineClock(deadlineGate),
        consume: neverReadingConsume,
        auxiliary: noAuxiliary
      )
    }
    // The terminal is committed and joinable (repeated joins are safe); only then may the deadline
    // fire, so the win is genuinely a race under a committed completion.
    let observed = await stream.awaitTermination()
    #expect(observed == .completed(expected))
    await deadlineGate.release()

    // then
    let response = try requireResponse(await box.value())
    #expect(response == expected)
  }

  @Test func aDeadlineBeforeTheTerminalDrainsTheConsumerThenTimesOut() async throws {
    // given — a stream that parks after a partial delta and reports a may-have-started cancellation
    // once released; the deadline fires first
    let gate = NonCooperativeStreamGate()
    let stream = LLMEventStream.make { sink in
      _ = try? await sink.sendDelta("partial")
      await gate.markStartedAndWaitForRelease()
      return .cancelled(.mayHaveStarted(observing: 4))
    }

    // when
    let box = runOutcome {
      await ProviderDeadlineCoordinator.raceStreaming(
        stream: stream,
        deadlineSeconds: 180,
        clock: instantDeadlineClock,
        consume: accumulatingConsume,
        auxiliary: noAuxiliary
      )
    }
    await gate.waitUntilStarted()
    await gate.release()

    // then — the drained termination carries the disposition
    let accounting = try requireTimedOut(await box.value())
    #expect(accounting == .mayHaveStarted(observedCompletionTokens: 4))
  }

  @Test func aNotStartedStreamCancellationTimesOutWithNoDebit() async throws {
    // given — a stream that never starts the inference and reports notStarted on cancel
    let gate = NonCooperativeStreamGate()
    let stream = LLMEventStream.make { _ in
      await gate.markStartedAndWaitForRelease()
      return .cancelled(.notStarted)
    }

    // when
    let box = runOutcome {
      await ProviderDeadlineCoordinator.raceStreaming(
        stream: stream,
        deadlineSeconds: 180,
        clock: instantDeadlineClock,
        consume: accumulatingConsume,
        auxiliary: noAuxiliary
      )
    }
    await gate.waitUntilStarted()
    await gate.release()

    // then
    let accounting = try requireTimedOut(await box.value())
    #expect(accounting == .notStarted)
  }

  @Test func aFailedStreamSurfacesItsTypedFailure() async throws {
    // given
    let failure = ProviderFailure(
      cause: .retryable(status: nil, message: "mid-stream drop"),
      accounting: .mayHaveStarted(observedCompletionTokens: 0)
    )
    let stream = LLMEventStream.make { _ in
      .failed(failure)
    }

    // when
    let outcome = await ProviderDeadlineCoordinator.raceStreaming(
      stream: stream,
      deadlineSeconds: 180,
      clock: deadlineParkedUntilCancelledClock,
      consume: accumulatingConsume,
      auxiliary: noAuxiliary
    )

    // then
    let error = try requireFailed(outcome)
    #expect(error as? ProviderFailure == failure)
  }

  @Test(.timeLimit(.minutes(1)))
  func theCoordinatorDoesNotReturnBeforeANonCooperativeProducerJoins() async throws {
    // given — an inference that ignores cancellation until its gate opens. The deadline wins, so the
    // coordinator's one bounded join must wait for the producer to acknowledge before it returns.
    // The producer reports a distinctive observed count on release, which only the real join can
    // carry: a coordinator that returned before joining could not know it, so the value assertion
    // fails red — never hangs — when the drain is removed.
    let distinctiveObservedCount = 99
    let gate = NonCooperativeStreamGate()
    let stream = LLMEventStream.make { sink in
      _ = try? await sink.sendDelta("partial")
      await gate.markStartedAndWaitForRelease()
      return .cancelled(.mayHaveStarted(observing: distinctiveObservedCount))
    }
    let returned = CompletionFlag()

    // when
    let box = runOutcome {
      let outcome = await ProviderDeadlineCoordinator.raceStreaming(
        stream: stream,
        deadlineSeconds: 180,
        clock: instantDeadlineClock,
        consume: accumulatingConsume,
        auxiliary: noAuxiliary
      )
      await returned.markDone()
      return outcome
    }
    await gate.waitUntilStarted()
    // A yield lets a coordinator that returned before joining its producer surface, without a window.
    await Task.yield()
    let doneWhileProducerParked = await returned.done

    // then — the coordinator is still parked on the producer's join, and the outcome carries the
    // producer's real disposition rather than a synthesized one
    #expect(doneWhileProducerParked == false)
    await gate.release()
    let accounting = try requireTimedOut(await box.value())
    #expect(accounting == .mayHaveStarted(observedCompletionTokens: distinctiveObservedCount))
  }

  // MARK: - Bounded ephemeral send

  @Test func aBoundedSendReturnsWhenTheSendCompletes() async throws {
    // given
    let sent = CompletionFlag()

    // when — the deadline parks until cancelled, so the send wins
    await ProviderDeadlineCoordinator.sendBounded(
      timeout: .seconds(3),
      clock: deadlineParkedUntilCancelledClock,
      send: {
        await sent.markDone()
      }
    )

    // then
    #expect(await sent.done == true)
  }

  @Test(.timeLimit(.minutes(1)))
  func aBoundedSendAbandonsAndCancelsAHungSendAtTheTimeout() async throws {
    // given — a send that blocks until cancelled; the deadline fires instantly
    let send = GatedSend()

    // when
    await ProviderDeadlineCoordinator.sendBounded(
      timeout: .seconds(3),
      clock: instantDeadlineClock,
      send: {
        await send.run()
      }
    )

    // then — the send did not wedge the turn; it was cancelled and drained, never orphaned
    #expect(await send.started == true)
    #expect(await send.observedCancellation == true)
  }

  @Test(.timeLimit(.minutes(1)))
  func aWonDeadlineDrainsAGatedAuxiliaryChild() async throws {
    // given — the provider wins via a completed stream, while the auxiliary loop is parked behind a
    // cancellation-aware gate. The coordinator must cancel and drain it before returning.
    let expected = racedResponse(content: "provider wins")
    let stream = LLMEventStream.make { sink in
      _ = try? await sink.sendDelta("provider wins")
      return .completed(expected)
    }
    let auxGate = GatedSend()

    // when
    let outcome = await ProviderDeadlineCoordinator.raceStreaming(
      stream: stream,
      deadlineSeconds: 180,
      clock: deadlineParkedUntilCancelledClock,
      consume: accumulatingConsume,
      auxiliary: { _ in
        await auxGate.run()
      }
    )

    // then — the response returns and the auxiliary child was cancelled and drained
    let response = try requireResponse(outcome)
    #expect(response == expected)
    #expect(await auxGate.observedCancellation == true)
  }
}
