import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawCore

/// The suite's time limit is a deadlock guard, never a synchronization mechanism: every wakeup a
/// test needs is driven by a gate, by the stream's own bookkeeping, or by the producer reporting, so
/// a lost resume fails here loudly instead of wedging the run.
@Suite(.timeLimit(.minutes(1)))
enum LLMEventStreamTests {
  // MARK: - Terminal outcomes

  @Suite struct TerminalOutcomes {
    @Test func deliversDeltasThenTheReservedTerminalEvent() async throws {
      // given a producer that streams two deltas and reports a whole reply
      let stream = LLMEventStream.make { sink in
        try? await sink.sendDelta("he")
        try? await sink.sendDelta("llo")
        return .completed(wholeReply)
      }

      // when the consumer reads the sequence to its end and joins
      let events = try await collect(stream)
      let terminal = await stream.awaitTermination()

      // then the terminal event trails the deltas, and the join carries the authoritative reply
      #expect(events == [.delta("he"), .delta("llo"), wholeReplyEvent])
      #expect(terminal == .completed(wholeReply))
    }

    @Test func throwsANaturalFailureFromTheIteratorAndCachesItsTypedCause() async throws {
      // given a producer that streams part of a reply and then fails for a real reason
      let failure = ProviderFailure(
        cause: .retryable(status: 503, message: "upstream unavailable"),
        accounting: .mayHaveStarted(observing: 4)
      )
      let stream = LLMEventStream.make { sink in
        try? await sink.sendDelta("partial")
        return .failed(failure)
      }

      // when the consumer reads
      var events: [StreamEvent] = []
      var caught: (any Error)?
      do {
        for try await event in stream {
          events.append(event)
        }
      } catch {
        caught = error
      }

      // then the accepted delta survives, and joining does not erase the cause the iterator threw
      #expect(events == [.delta("partial")])
      #expect(caught as? ProviderFailure == failure)
      #expect(await stream.awaitTermination() == .failed(failure))
    }
  }

  // MARK: - Cancellation

  @Suite struct Cancellation {
    @Test func joinsAsNotStartedWhenCancelledBeforeTheProducerHandsOff() async throws {
      // given a producer parked before it has done any authorization or network work
      let reachedHandoff = AsyncGate()
      let releaseHandoff = AsyncGate()
      defer { releaseHandoff.open() }
      let stream = LLMEventStream.make { _ in
        reachedHandoff.open()
        await releaseHandoff.wait()
        return Task.isCancelled ? .cancelled(.notStarted) : .completed(wholeReply)
      }
      await reachedHandoff.wait()

      // when the holder cancels and joins
      let terminal = await stream.cancelAndAwait()

      // then merely holding a session never claimed that inference started
      #expect(terminal == .cancelled(.notStarted))
      #expect(try await collect(stream).isEmpty)
    }

    @Test func joinsWithObservedTokensWhenCancelledAfterExposure() async throws {
      // given a producer that has already streamed visible output
      let exposed = AsyncGate()
      let releaseProducer = AsyncGate()
      defer { releaseProducer.open() }
      let stream = LLMEventStream.make { sink in
        try? await sink.sendDelta("partial")
        exposed.open()
        await releaseProducer.wait()
        return .cancelled(.mayHaveStarted(observing: 2))
      }
      await exposed.wait()

      // when the holder cancels and joins
      let terminal = await stream.cancelAndAwait()

      // then the join carries the lower bound the producer observed, not a bare cancellation
      #expect(terminal == .cancelled(.mayHaveStarted(observedCompletionTokens: 2)))
    }

    @Test func unwindsAProducerBlockedOnAFullEventChannel() async throws {
      // given a producer parked on a delta the full channel cannot admit
      let blockedSendFailed = Mutex(false)
      let stream = LLMEventStream.make(limits: tinyLimits) { sink in
        try? await sink.sendDelta("first")
        try? await sink.sendDelta("second")
        do {
          try await sink.sendDelta("third")
        } catch {
          blockedSendFailed.withLock { current in
            current = true
          }
        }
        return .cancelled(.mayHaveStarted(observing: 1))
      }
      await waitUntil("the third delta parks on the full channel") {
        stream.suspendedDeltaSenderCount == 1
      }

      // when the holder cancels and joins
      let terminal = await stream.cancelAndAwait()

      // then the parked producer was resumed rather than stranded, so the join could not deadlock
      #expect(terminal == .cancelled(.mayHaveStarted(observedCompletionTokens: 1)))
      #expect(blockedSendFailed.withLock { current in current })
      #expect(stream.suspendedDeltaSenderCount == 0)
    }

    @Test func cancellationImmediatelyBeforeTheTerminalCommitWins() async throws {
      // given a producer holding a whole reply it has not yet reported
      let readyToCommit = AsyncGate()
      let mayCommit = AsyncGate()
      defer { mayCommit.open() }
      let stream = LLMEventStream.make { _ in
        readyToCommit.open()
        await mayCommit.waitIgnoringCancellation()
        return .completed(wholeReply)
      }
      await readyToCommit.wait()

      // when cancellation lands first and only then does the producer insist it completed
      stream.cancel()
      mayCommit.open()
      let terminal = await stream.awaitTermination()

      // then cancellation wins, no terminal event was reserved, and the tokens seen are reported
      #expect(terminal == .cancelled(.mayHaveStarted(observedCompletionTokens: 7)))
      #expect(try await collect(stream).isEmpty)
    }

    @Test func cancellationImmediatelyAfterTheTerminalCommitIsANoOp() async throws {
      // given a stream whose terminal has provably landed
      let stream = LLMEventStream.make { _ in
        .completed(wholeReply)
      }
      let committed = await stream.awaitTermination()

      // when cancellation arrives afterwards
      stream.cancel()

      // then completion stands, and the reserved terminal event is still delivered
      #expect(committed == .completed(wholeReply))
      #expect(await stream.awaitTermination() == .completed(wholeReply))
      #expect(try await collect(stream) == [wholeReplyEvent])
    }

    @Test func abandoningTheIteratorCancelsTheProducer() async throws {
      // given a producer that would stream deltas forever
      let stream = LLMEventStream.make(limits: tinyLimits) { sink in
        while true {
          do {
            try await sink.sendDelta("x")
          } catch {
            return .cancelled(.notStarted)
          }
        }
      }

      // when a consumer reads one event and walks away, releasing its iterator
      try await readOneEventAndWalkAway(from: stream)

      // then the abandoned iteration stopped the producer, and the join still reports what it did
      #expect(await stream.awaitTermination() == .cancelled(.notStarted))
    }
  }

  // MARK: - Joining

  @Suite struct Joining {
    @Test func everyJoinerSharesOneCachedTerminal() async throws {
      // given a stream whose producer has not reported yet
      let mayFinish = AsyncGate()
      defer { mayFinish.open() }
      let stream = LLMEventStream.make { _ in
        await mayFinish.waitIgnoringCancellation()
        return .completed(wholeReply)
      }
      async let first = stream.awaitTermination()
      async let second = stream.awaitTermination()
      await waitUntil("both joiners park on the undecided terminal") {
        stream.parkedJoinerCount == 2
      }

      // when the producer reports
      mayFinish.open()
      let parkedResults = await [first, second]

      // then parked, repeated, and late joiners all read the same one value
      #expect(parkedResults == [.completed(wholeReply), .completed(wholeReply)])
      #expect(await stream.awaitTermination() == .completed(wholeReply))
      #expect(await stream.cancelAndAwait() == .completed(wholeReply))
      #expect(stream.parkedJoinerCount == 0)
    }

    @Test func joinersResumeOnlyAfterTheProducerReturnsFromCleanup() async throws {
      // given a producer whose cleanup — standing in for joining a nested HTTP exchange — is held
      let cleanupStarted = AsyncGate()
      let cleanupMayReturn = AsyncGate()
      defer { cleanupMayReturn.open() }
      let cleanupReturned = Mutex(false)
      let stream = LLMEventStream.make { _ in
        cleanupStarted.open()
        await cleanupMayReturn.waitIgnoringCancellation()
        cleanupReturned.withLock { current in
          current = true
        }
        return .cancelled(.notStarted)
      }
      let joiner = Task {
        await stream.awaitTermination()
      }
      await waitUntil("the joiner parks") {
        stream.parkedJoinerCount == 1
      }

      // when cancellation is signalled and the producer enters cleanup it cannot yet leave
      stream.cancel()
      await cleanupStarted.wait()

      // then the decided cancellation has not released the joiner: releasing it is the producer's
      // last act, so a joiner still parked here is the whole guarantee
      #expect(stream.parkedJoinerCount == 1)
      #expect(cleanupReturned.withLock { current in !current })

      // when cleanup returns
      cleanupMayReturn.open()

      // then the joiner resumes, and only then
      #expect(await joiner.value == .cancelled(.notStarted))
      #expect(cleanupReturned.withLock { current in current })
    }

    @Test func awaitTerminationIgnoresTheJoinersOwnCancellation() async throws {
      // given a joiner parked on a stream whose producer has not reported
      let mayFinish = AsyncGate()
      defer { mayFinish.open() }
      let stream = LLMEventStream.make { _ in
        await mayFinish.waitIgnoringCancellation()
        return .completed(wholeReply)
      }
      let joiner = Task {
        await stream.awaitTermination()
      }
      await waitUntil("the joiner parks") {
        stream.parkedJoinerCount == 1
      }

      // when the joiner's own task is cancelled
      joiner.cancel()

      // then it stays parked rather than fabricating an answer the producer never gave
      #expect(stream.parkedJoinerCount == 1)
      mayFinish.open()
      #expect(await joiner.value == .completed(wholeReply))
    }
  }

  // MARK: - Default budget

  @Suite struct DefaultBudget {
    @Test func pinsTheProviderDefaultBudgetAndItsExactSlotDivision() {
      // given the budget every stream runs on unless its caller names another
      let limits = LLMEventBufferLimits.providerDefault

      // when a delta is weighed against it at the slot floor
      let slotCharge = limits.deltaCharge(forTextBytes: 1)

      // then the three bounds are the ones the budget was agreed at
      #expect(limits.maximumDeltaCount == 1024)
      #expect(limits.maximumDeltaBytes == 5 * 1024 * 1024)
      #expect(limits.reservedTerminalBytes == 5 * 1024 * 1024)
      // and the count bound spends the byte budget exactly. A count that does not divide the bytes
      // rounds the slot down and strands the remainder: both bounds still hold, so every other test
      // here stays green while the queue quietly stops at less than the budget it was given.
      #expect(slotCharge * limits.maximumDeltaCount == limits.maximumDeltaBytes)
    }
  }

  // MARK: - Buffer bounds

  @Suite struct BufferBounds {
    @Test func boundsTheDeltaQueueByCountWhenDeltasAreTiny() async throws {
      // given a queue budgeted for three deltas across three hundred bytes
      let limits = LLMEventBufferLimits(
        maximumDeltaCount: 3,
        maximumDeltaBytes: 300,
        reservedTerminalBytes: 128
      )
      let stream = LLMEventStream.make(limits: limits) { sink in
        for _ in 0..<4 {
          try? await sink.sendDelta("x")
        }
        return .cancelled(.notStarted)
      }

      // when four one-byte deltas are offered

      // then the count bound holds even though their payload is nowhere near three hundred bytes
      await waitUntil("the fourth tiny delta parks") {
        stream.suspendedDeltaSenderCount == 1
      }
      _ = await stream.cancelAndAwait()
    }

    @Test func boundsTheDeltaQueueByPayloadWhenDeltasAreLarge() async throws {
      // given a queue budgeted for ten deltas across a hundred bytes
      let limits = LLMEventBufferLimits(
        maximumDeltaCount: 10,
        maximumDeltaBytes: 100,
        reservedTerminalBytes: 128
      )
      let stream = LLMEventStream.make(limits: limits) { sink in
        for _ in 0..<2 {
          try? await sink.sendDelta(String(repeating: "z", count: 60))
        }
        return .cancelled(.notStarted)
      }

      // when two sixty-byte deltas are offered

      // then the byte bound holds first: a count-bounded queue would have taken both
      await waitUntil("the second large delta parks") {
        stream.suspendedDeltaSenderCount == 1
      }
      _ = await stream.cancelAndAwait()
    }

    @Test func rejectsADeltaLargerThanTheWholeDeltaBudget() async throws {
      // given a delta no drain could ever make room for
      let sendFailure = Mutex<BoundedAsyncChannelError?>(nil)
      let stream = LLMEventStream.make(limits: tinyLimits) { sink in
        do {
          try await sink.sendDelta(String(repeating: "z", count: 65))
        } catch {
          sendFailure.withLock { current in
            current = error as? BoundedAsyncChannelError
          }
        }
        return .cancelled(.notStarted)
      }

      // when the producer offers it
      _ = await stream.awaitTermination()

      // then it is refused outright rather than parking the producer forever
      #expect(
        sendFailure.withLock { current in current }
          == .elementExceedsCapacity(weight: 65, capacity: 64)
      )
    }
  }

  // MARK: - Terminal reservation

  @Suite struct TerminalReservation {
    @Test func commitsAMaximumSizeTerminalAgainstAFullDeltaQueue() async throws {
      // given a full delta queue and a reply that exactly fills the terminal reservation
      let maximumReply = ChatResponse(
        content: String(repeating: "z", count: 128),
        finishReason: "stop",
        usage: nil,
        costFromProvider: nil
      )
      let stream = LLMEventStream.make(limits: tinyLimits) { sink in
        try? await sink.sendDelta("first")
        try? await sink.sendDelta("second")
        return .completed(maximumReply)
      }

      // when the holder joins without draining a single delta first
      let terminal = await stream.awaitTermination()

      // then the reservation carried the terminal past a queue with no room left in it
      #expect(terminal == .completed(maximumReply))
      let events = try await collect(stream)
      #expect(
        events == [
          .delta("first"),
          .delta("second"),
          .finished(finishReason: "stop", usage: nil, providerCost: nil, toolCalls: []),
        ]
      )
    }

    @Test func failsSafelyWhenTheTerminalOutgrowsItsReservation() async throws {
      // given a reply one byte past the reservation
      let oversizedReply = ChatResponse(
        content: String(repeating: "z", count: 129),
        finishReason: "stop",
        usage: ChatUsage(promptTokens: 1, completionTokens: 9, totalTokens: 10),
        costFromProvider: nil
      )
      let stream = LLMEventStream.make(limits: tinyLimits) { _ in
        .completed(oversizedReply)
      }

      // when the holder joins
      let terminal = await stream.awaitTermination()

      // then it fails with a redaction-safe cause and keeps the tokens the reply already showed
      #expect(
        terminal
          == .failed(
            ProviderFailure(
              cause: .terminal(
                status: nil,
                message: "streamed reply exceeded the 128-byte terminal reservation"
              ),
              accounting: .mayHaveStarted(observing: 9)
            )
          )
      )
    }

    @Test func chargesToolArgumentsAndReplayStateAgainstTheReservation() async throws {
      // given a reply whose visible text is tiny but whose tool call and replay state are not
      let statefulReply = ChatResponse(
        content: "hi",
        finishReason: "tool_calls",
        usage: nil,
        costFromProvider: nil,
        toolCalls: [ToolCall(id: "call-1", name: "fetch", argumentsJSON: "{\"url\":\"x\"}")],
        providerState: ProviderExchangeState(
          issuer: "chatgpt",
          payload: Data(repeating: 0, count: 4)
        )
      )
      let limits = LLMEventBufferLimits(
        maximumDeltaCount: 2,
        maximumDeltaBytes: 64,
        reservedTerminalBytes: 32
      )
      let stream = LLMEventStream.make(limits: limits) { _ in
        .completed(statefulReply)
      }

      // when the holder joins
      let terminal = await stream.awaitTermination()

      // then the reservation counted every byte it must hold: weighing content alone would admit it
      #expect(
        terminal
          == .failed(
            ProviderFailure(
              cause: .terminal(
                status: nil,
                message: "streamed reply exceeded the 32-byte terminal reservation"
              ),
              accounting: .mayHaveStarted(observing: 0)
            )
          )
      )
    }
  }
}

// MARK: - Support

/// A queue budgeted for two deltas across sixty-four bytes, so a five-byte delta charges the
/// thirty-two-byte slot and two of them leave no room at all.
private let tinyLimits = LLMEventBufferLimits(
  maximumDeltaCount: 2,
  maximumDeltaBytes: 64,
  reservedTerminalBytes: 128
)

private let wholeReply = ChatResponse(
  content: "hello",
  finishReason: "stop",
  usage: ChatUsage(promptTokens: 3, completionTokens: 7, totalTokens: 10),
  costFromProvider: nil
)

private let wholeReplyEvent = StreamEvent.finished(
  finishReason: "stop",
  usage: ChatUsage(promptTokens: 3, completionTokens: 7, totalTokens: 10),
  providerCost: nil,
  toolCalls: []
)

private func collect(_ stream: LLMEventStream) async throws -> [StreamEvent] {
  var received: [StreamEvent] = []
  for try await event in stream {
    received.append(event)
  }
  return received
}

/// Reads one event and returns, so the iterator is released at a point the test controls rather than
/// wherever the optimizer decides a local dies.
private func readOneEventAndWalkAway(from stream: LLMEventStream) async throws {
  var iterator = stream.makeAsyncIterator()
  _ = try await iterator.next()
}
