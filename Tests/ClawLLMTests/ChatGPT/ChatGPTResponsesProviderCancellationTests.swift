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
@Suite
struct ChatGPTResponsesProviderCancellationTests {
  @Test(.timeLimit(.minutes(1)))
  func rotatedCredentialsSplitAcrossProgressAreRedacted() async throws {
    // given — a clean 401 rotates credentials before the only successful inference begins
    let hold = ScriptedStreamHold()
    defer { hold.release.open() }
    let progressSeen = AsyncGate()
    let credentials = RotatingProgressCredentialSource()
    let frames = [
      Fixtures.event(
        #"""
        {"type":"response.output_item.added","output_index":0,\#
        "item":{"type":"message","phase":"commentary"}}
        """#
      ),
      Fixtures.event(
        #"""
        {"type":"response.output_text.delta","output_index":0,\#
        "delta":"Using oauth-old-"}
        """#
      ),
      Fixtures.event(
        #"""
        {"type":"response.output_text.delta","output_index":0,\#
        "delta":"synthetic and oauth-new-\u0000"}
        """#
      ),
      Fixtures.event(
        #"""
        {"type":"response.output_text.delta","output_index":0,\#
        "delta":"synthetic safely"}
        """#
      ),
    ]
    let harness = ProviderHarness(
      steps: [
        .stream(Support.head(401), Fixtures.errorBody("expired")),
        .streamThenBlock(okHead, frames, hold),
      ],
      credentials: credentials
    )
    let request = ChatRequest(
      model: "gpt-5",
      messages: plainRequest.messages,
      maxOutputTokens: 256,
      progressExplanationsEnabled: true
    )
    let stream = harness.provider.stream(request: request)
    let reader = Task { () -> String in
      var displayed = ""
      do {
        for try await event in stream {
          if case .progress(let progress) = event {
            switch progress.text {
            case .append(let text):
              displayed += text
            case .replace(let text):
              displayed = text
            case .complete:
              break
            }
            if displayed.contains("safely") {
              progressSeen.open()
            }
          } else if case .delta = event {
            Issue.record("progress became answer text")
          }
        }
      } catch {
        Issue.record("unexpected progress reader failure: \(error)")
      }
      return displayed
    }

    // when — only a real display event signals readiness; the watchdog bounds missing progress
    let sawProgress = await progressSeen.waitUntilOpen()
    await hold.started.wait()
    stream.cancel()
    let joiner = Task {
      await stream.awaitTermination()
    }
    hold.release.open()
    let terminal = await joiner.value
    let displayed = await reader.value

    // then — progress alone retains conservative exposure, while cleanup owns the nested producer
    #expect(sawProgress)
    #expect(terminal == .cancelled(.mayHaveStarted(observing: 0)))
    #expect(displayed.contains("oauth-old-synthetic") == false)
    #expect(displayed.contains("oauth-new-synthetic") == false)
    #expect(displayed.components(separatedBy: SecretRedactor.replacement).count == 3)
    #expect(await harness.http.recorded.count == 2)
  }

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
    let harness = ProviderHarness(steps: [
      .blockedStream(okHead, Fixtures.basicSuccess(), ScriptedStreamHold(release: gate)),
    ])

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
  func abandoningAHeldOpenIteratorCancelsWithConservativeAccounting() async throws {
    // given — the HTTP producer emits a delta, then remains live until the test releases it
    let hold = ScriptedStreamHold()
    defer { hold.release.open() }
    let harness = ProviderHarness(steps: [.streamThenBlock(okHead, Fixtures.slowSuccess(), hold)])
    let stream = harness.provider.stream(request: plainRequest)

    // when — the helper returns only after reading a real delta while the transfer is held open;
    // returning releases the iterator before this test joins the owning stream
    try await readOneDeltaAndAbandon(from: stream, onceProducerIsHeldBy: hold)
    hold.release.open()

    // then — iterator abandonment, rather than natural EOF, cancelled the live inference
    let terminal = await stream.awaitTermination()
    guard case .cancelled(let accounting) = terminal else {
      Issue.record("expected iterator abandonment to cancel the stream, got \(terminal)")
      return
    }
    #expect(Support.isConservative(accounting))
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

  @Test(.timeLimit(.minutes(1)))
  func localOutputLimitCancelsAndJoinsTheHeldHTTPProducer() async throws {
    // given — the first visible delta crosses the evaluation cap, while the HTTP producer remains
    // held after sending it and deliberately ignores cancellation until the test releases it
    let hold = ScriptedStreamHold()
    let harness = ProviderHarness(
      steps: [.streamThenBlock(okHead, Fixtures.slowSuccess(), hold)],
      retryBudget: 1
    )
    let limiter = AttemptOutputLimiter(
      limits: AttemptOutputLimits(maximumUTF8Bytes: 4, maximumGraphemes: 4)
    )
    let request = ChatRequest(
      model: "gpt-5",
      messages: [ChatMessage(role: .user, content: "hello")],
      maxOutputTokens: 256,
      outputScope: limiter.beginRound()
    )
    let completion = CompletionFlag()

    // when
    let task = Task {
      do {
        _ = try await harness.provider.complete(request: request)
        Issue.record("expected local output limit")
        return ProviderFailure(
          cause: .terminal(status: nil, message: "test"),
          accounting: .notStarted
        )
      } catch let failure as ProviderFailure {
        await completion.markDone()
        return failure
      } catch {
        Issue.record("expected ProviderFailure, got \(error)")
        return ProviderFailure(
          cause: .terminal(status: nil, message: "test"),
          accounting: .notStarted
        )
      }
    }
    await hold.started.wait()
    await Task.yield()
    let returnedBeforeJoin = await completion.done
    hold.release.open()
    let failure = await task.value

    // then
    #expect(returnedBeforeJoin == false)
    #expect(failure.cause == .localOutputLimit)
    // "Hello" is five graphemes; the production conservative double-ceil estimator records 3.
    #expect(failure.accounting == .mayHaveStarted(observing: 3))
    #expect(limiter.counts.limitExceeded)
  }

  @Test(.timeLimit(.minutes(1)))
  func streamedToolArgumentsCrossingTheLocalLimitCancelAndJoinTheHTTPProducer() async throws {
    // given — there is no owner-visible text. The streamed function arguments alone exceed the
    // cap while the HTTP producer remains live and cancellation-noncooperative behind the hold.
    let hold = ScriptedStreamHold()
    let argumentEvents = [
      Fixtures.event(
        #"""
        {"type":"response.output_item.added","output_index":0,\#
        "item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"clock"}}
        """#
      ),
      Fixtures.event(
        #"""
        {"type":"response.function_call_arguments.delta","output_index":0,\#
        "item_id":"fc_1","call_id":"call_a","delta":"{\"abcdef\":1}"}
        """#
      ),
    ]
    let harness = ProviderHarness(
      steps: [.streamThenBlock(okHead, argumentEvents, hold)],
      retryBudget: 1
    )
    let limiter = AttemptOutputLimiter(
      limits: AttemptOutputLimits(maximumUTF8Bytes: 4, maximumGraphemes: 4)
    )
    let request = ChatRequest(
      model: "gpt-5",
      messages: [ChatMessage(role: .user, content: "hello")],
      maxOutputTokens: 256,
      tools: [Support.clockTool],
      outputScope: limiter.beginRound()
    )
    let completion = CompletionFlag()

    // when
    let task = Task {
      do {
        _ = try await harness.provider.complete(request: request)
        Issue.record("expected local output limit")
        return ProviderFailure(
          cause: .terminal(status: nil, message: "test"),
          accounting: .notStarted
        )
      } catch let failure as ProviderFailure {
        await completion.markDone()
        return failure
      } catch {
        Issue.record("expected ProviderFailure, got \(error)")
        return ProviderFailure(
          cause: .terminal(status: nil, message: "test"),
          accounting: .notStarted
        )
      }
    }
    await hold.started.wait()
    await Task.yield()
    let returnedBeforeJoin = await completion.done
    hold.release.open()
    let failure = await task.value

    // then — a provider that only charges visible text would not fail; a provider that cancels but
    // does not join would return while the deliberately held producer is still alive.
    #expect(returnedBeforeJoin == false)
    #expect(failure.cause == .localOutputLimit)
    guard case .mayHaveStarted(let observedTokens) = failure.accounting else {
      Issue.record("expected conservative accounting after streamed arguments")
      return
    }
    #expect(observedTokens > 0)
    #expect(limiter.counts.utf8Bytes == 12)
    #expect(limiter.counts.limitExceeded)
  }
}

private func readOneDeltaAndAbandon(
  from stream: LLMEventStream,
  onceProducerIsHeldBy hold: ScriptedStreamHold
) async throws {
  var iterator = stream.makeAsyncIterator()
  #expect(try await iterator.next() == .delta("Hello"))
  await hold.started.wait()
}

// MARK: - Test doubles

private actor RotatingProgressCredentialSource: LLMCredentialSource {
  private var generation: UInt64 = 0

  func authorization() async throws -> LLMRequestAuthorization {
    let token = generation == 0 ? "oauth-old-synthetic" : "oauth-new-synthetic"
    return LLMRequestAuthorization(
      headers: ["Authorization": "Bearer \(token)"],
      redactionValues: [token],
      generation: LLMCredentialGeneration(value: generation)
    )
  }

  func reject(generation: LLMCredentialGeneration, disposition: LLMCredentialRejection) async {
    if generation.value == self.generation, disposition == .refresh {
      self.generation += 1
    }
  }

  func shutdown() async throws {}
}

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

// MARK: - Shared support

private typealias Support = ChatGPTProviderTestSupport
private typealias ProviderHarness = Support.Harness
private typealias Fixtures = Support.Fixtures

private let okHead = Support.okHead
private let plainRequest = Support.plainRequest
