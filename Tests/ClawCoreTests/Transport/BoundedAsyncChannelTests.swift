import ClawTestSupport
import Testing

@testable import ClawCore

/// The suite's time limit is a deadlock guard, never a synchronization mechanism: every wakeup a
/// test needs is driven by a gate or by the channel itself, so a lost resume fails here loudly
/// instead of wedging the run.
@Suite(.timeLimit(.minutes(1)))
enum BoundedAsyncChannelTests {
  // MARK: - Delivery

  @Suite struct Delivery {
    @Test func deliversElementsInSendOrder() async throws {
      // given
      let channel = BoundedAsyncChannel<Int>(capacity: 3)

      // when
      try await channel.send(1)
      try await channel.send(2)
      try await channel.send(3)
      channel.finish()

      // then
      let received = try await collect(channel)
      #expect(received == [1, 2, 3])
    }

    @Test func suspendsTheProducerWhenTheBufferIsFull() async throws {
      // given a channel with room for exactly one element, already holding it
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      try await channel.send(1)

      // when a second send arrives
      let producer = Task {
        try await channel.send(2)
      }
      await waitUntil("the producer parks on the full buffer") {
        channel.suspendedSenderCount == 1
      }

      // then it waits for a drain rather than dropping its element
      var iterator = channel.makeAsyncIterator()
      let first = try await iterator.next()
      try await producer.value
      let second = try await iterator.next()
      channel.finish()
      let terminator = try await iterator.next()
      #expect(first == 1)
      #expect(second == 2)
      #expect(terminator == nil)
      #expect(channel.suspendedSenderCount == 0)
    }

    @Test func boundsTheBufferByWeightRatherThanElementCount() async throws {
      // given a channel that admits ten units of weight, each element weighing its own value
      let channel = BoundedAsyncChannel<Int>(capacity: 10) { element in
        element
      }

      // when two elements fill the weight cap and a third arrives
      try await channel.send(6)
      try await channel.send(4)
      let producer = Task {
        try await channel.send(1)
      }
      await waitUntil("the third send parks") {
        channel.suspendedSenderCount == 1
      }

      // then the cap is measured in weight: a count-bounded buffer would have taken the third
      var iterator = channel.makeAsyncIterator()
      let first = try await iterator.next()
      try await producer.value
      #expect(first == 6)
      #expect(channel.suspendedSenderCount == 0)
    }

    @Test func boundsElementCountWhenEveryElementWeighsNothing() async throws {
      // given a channel with room for one unit, and a weight function that costs an element nothing
      let channel = BoundedAsyncChannel<Int>(capacity: 1) { _ in
        0
      }
      try await channel.send(1)

      // when a second weightless element arrives
      let producer = Task {
        try await channel.send(2)
      }
      await waitUntil("the weightless producer parks") {
        channel.suspendedSenderCount == 1
      }

      // then a free payload still costs its slot: without a floor the buffer would grow forever
      #expect(channel.suspendedSenderCount == 1)
      var iterator = channel.makeAsyncIterator()
      let first = try await iterator.next()
      try await producer.value
      let second = try await iterator.next()
      #expect(first == 1)
      #expect(second == 2)
      #expect(channel.suspendedSenderCount == 0)
    }

    @Test func admitsParkedSendersInSendOrder() async throws {
      // given two producers parked on a full channel, in a known order
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      try await channel.send(1)
      let second = Task {
        try await channel.send(2)
      }
      await waitUntil("the first producer parks") {
        channel.suspendedSenderCount == 1
      }
      let third = Task {
        try await channel.send(3)
      }
      await waitUntil("the second producer parks") {
        channel.suspendedSenderCount == 2
      }

      // when the channel drains
      var iterator = channel.makeAsyncIterator()
      let first = try await iterator.next()
      try await second.value
      let secondElement = try await iterator.next()
      try await third.value
      let thirdElement = try await iterator.next()

      // then the parked producers were admitted in send order
      #expect([first, secondElement, thirdElement] == [1, 2, 3])
    }

    @Test func deliversDirectlyToAReceiverParkedBeforeTheSend() async throws {
      // given a consumer parked on an empty channel
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      let consumer = Task { () -> Int? in
        var iterator = channel.makeAsyncIterator()
        return try await iterator.next()
      }
      await waitUntil("the consumer parks") {
        channel.suspendedReceiverCount == 1
      }

      // when an element is sent
      try await channel.send(7)

      // then it went straight to the receiver: the buffer never held it, so the next send fits
      try await channel.send(8)
      let received = try await consumer.value
      #expect(received == 7)
      #expect(channel.suspendedSenderCount == 0)
      #expect(channel.suspendedReceiverCount == 0)
    }
  }

  // MARK: - Termination

  @Suite struct Termination {
    @Test func finishDeliversBufferedElementsBeforeTheEnd() async throws {
      // given
      let channel = BoundedAsyncChannel<Int>(capacity: 2)
      try await channel.send(1)
      try await channel.send(2)

      // when
      channel.finish()

      // then closing does not discard what was already accepted
      let received = try await collect(channel)
      #expect(received == [1, 2])
    }

    @Test func finishThrowingDeliversBufferedElementsBeforeTheError() async throws {
      // given
      let channel = BoundedAsyncChannel<Int>(capacity: 2)
      try await channel.send(1)

      // when
      channel.finish(throwing: StreamFailure())

      // then the accepted element still arrives, then the failure, then the end of the sequence
      var iterator = channel.makeAsyncIterator()
      let first = try await iterator.next()
      var failure: (any Error)?
      do {
        _ = try await iterator.next()
      } catch {
        failure = error
      }
      let afterFailure = try await iterator.next()
      #expect(first == 1)
      #expect(failure is StreamFailure)
      #expect(afterFailure == nil)
    }

    @Test func repeatedFinishKeepsTheFirstTermination() async throws {
      // given a channel closed cleanly
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      channel.finish()

      // when it is closed again, both ways
      channel.finish(throwing: StreamFailure())
      channel.finish()

      // then the first close won: a later failure cannot rewrite a completed sequence
      let received = try await collect(channel)
      #expect(received.isEmpty)
    }

    @Test func finishWakesEveryParkedProducer() async throws {
      // given two producers parked on a full channel
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      try await channel.send(1)
      let second = Task {
        try await channel.send(2)
      }
      await waitUntil("the first producer parks") {
        channel.suspendedSenderCount == 1
      }
      let third = Task {
        try await channel.send(3)
      }
      await waitUntil("the second producer parks") {
        channel.suspendedSenderCount == 2
      }

      // when
      channel.finish()

      // then every parked producer is resumed, not only the head of the queue
      await #expect(throws: BoundedAsyncChannelError.channelFinished) {
        try await second.value
      }
      await #expect(throws: BoundedAsyncChannelError.channelFinished) {
        try await third.value
      }
      #expect(channel.suspendedSenderCount == 0)
    }

    @Test func finishThrowingWakesAParkedProducerWithTheRefusal() async throws {
      // given a producer parked on a full channel
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      try await channel.send(1)
      let producer = Task {
        try await channel.send(2)
      }
      await waitUntil("the producer parks on the full buffer") {
        channel.suspendedSenderCount == 1
      }

      // when the channel is closed with an error
      channel.finish(throwing: StreamFailure())

      // then the producer learns its send was refused, not why the sequence ended: the terminal
      // error is the consumer's to observe
      await #expect(throws: BoundedAsyncChannelError.channelFinished) {
        try await producer.value
      }
      #expect(channel.suspendedSenderCount == 0)
    }

    @Test func finishWakesAParkedConsumer() async throws {
      // given a consumer parked on an empty channel
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      let consumer = Task { () -> Int? in
        var iterator = channel.makeAsyncIterator()
        return try await iterator.next()
      }
      await waitUntil("the consumer parks") {
        channel.suspendedReceiverCount == 1
      }

      // when
      channel.finish()

      // then
      let received = try await consumer.value
      #expect(received == nil)
      #expect(channel.suspendedReceiverCount == 0)
    }

    @Test func finishThrowingWakesAParkedConsumerWithTheError() async throws {
      // given a consumer parked on an empty channel
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      let consumer = Task { () -> Int? in
        var iterator = channel.makeAsyncIterator()
        return try await iterator.next()
      }
      await waitUntil("the consumer parks") {
        channel.suspendedReceiverCount == 1
      }

      // when
      channel.finish(throwing: StreamFailure())

      // then
      await #expect(throws: StreamFailure.self) {
        try await consumer.value
      }
      #expect(channel.suspendedReceiverCount == 0)
    }

    @Test func rejectsASendAfterFinish() async throws {
      // given
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      channel.finish()

      // when / then
      await #expect(throws: BoundedAsyncChannelError.channelFinished) {
        try await channel.send(1)
      }
    }
  }

  // MARK: - Cancellation

  @Suite struct Cancellation {
    @Test func cancellingAParkedProducerRemovesItsElement() async throws {
      // given a producer parked on a full channel
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      try await channel.send(1)
      let producer = Task {
        try await channel.send(2)
      }
      await waitUntil("the producer parks on the full buffer") {
        channel.suspendedSenderCount == 1
      }

      // when it is cancelled while suspended
      producer.cancel()

      // then it unwinds instead of waiting for a drain, and leaves the waiter set
      await #expect(throws: CancellationError.self) {
        try await producer.value
      }
      #expect(channel.suspendedSenderCount == 0)

      // and its element was never queued
      channel.finish()
      let received = try await collect(channel)
      #expect(received == [1])
    }

    @Test func cancellingAParkedConsumerRemovesIt() async throws {
      // given a consumer parked on an empty channel
      let channel = BoundedAsyncChannel<Int>(capacity: 2)
      let consumer = Task { () -> Int? in
        var iterator = channel.makeAsyncIterator()
        return try await iterator.next()
      }
      await waitUntil("the consumer parks") {
        channel.suspendedReceiverCount == 1
      }

      // when
      consumer.cancel()

      // then
      await #expect(throws: CancellationError.self) {
        try await consumer.value
      }
      #expect(channel.suspendedReceiverCount == 0)

      // and a later send buffers instead of resuming the removed receiver a second time
      try await channel.send(5)
      #expect(channel.suspendedSenderCount == 0)
    }

    @Test func rejectsASendFromAnAlreadyCancelledTask() async throws {
      // given a producer, cancelled before it reaches a channel with room to spare
      let channel = BoundedAsyncChannel<Int>(capacity: 4)
      let release = AsyncGate()
      let producer = Task {
        // Wedge semantics: only `open()` may release this task, so the send below — not the gate —
        // is what observes the cancellation.
        await release.waitIgnoringCancellation()
        try await channel.send(1)
      }

      // when
      producer.cancel()
      release.open()

      // then cancellation is observed during registration, not only while parked
      await #expect(throws: CancellationError.self) {
        try await producer.value
      }
      channel.finish()
      let received = try await collect(channel)
      #expect(received.isEmpty)
    }

    @Test func rejectsAReceiveFromAnAlreadyCancelledTask() async throws {
      // given an element ready to deliver and a consumer cancelled before it reads
      let channel = BoundedAsyncChannel<Int>(capacity: 4)
      try await channel.send(1)
      let release = AsyncGate()
      let consumer = Task { () -> Int? in
        await release.waitIgnoringCancellation()
        var iterator = channel.makeAsyncIterator()
        return try await iterator.next()
      }

      // when
      consumer.cancel()
      release.open()

      // then cancellation wins over a ready element rather than consuming it
      await #expect(throws: CancellationError.self) {
        try await consumer.value
      }
      #expect(channel.suspendedReceiverCount == 0)
    }

    @Test(arguments: 1...20)
    func settlesASendRacingCancellationExactlyOnce(iteration: Int) async throws {
      // given a producer and its canceller released at the same instant, so cancellation may land
      // before, during, or after the send registers its waiter
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      try await channel.send(1)
      let start = AsyncGate()
      let producer = Task {
        await start.wait()
        try await channel.send(2)
      }
      let canceller = Task {
        await start.wait()
        producer.cancel()
      }

      // when
      start.open()
      await canceller.value

      // then the send settles exactly once whichever side wins: a lost resume would hang here and
      // a double resume would trap
      await #expect(throws: CancellationError.self) {
        try await producer.value
      }
      #expect(channel.suspendedSenderCount == 0)

      // and the channel survives the race with its accepted element intact
      channel.finish()
      let received = try await collect(channel)
      #expect(received == [1])
    }

    @Test(arguments: 1...20)
    func settlesAReceiveRacingCancellationExactlyOnce(iteration: Int) async throws {
      // given a consumer and its canceller released at the same instant on an empty channel
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      let start = AsyncGate()
      let consumer = Task { () -> Int? in
        await start.wait()
        var iterator = channel.makeAsyncIterator()
        return try await iterator.next()
      }
      let canceller = Task {
        await start.wait()
        consumer.cancel()
      }

      // when
      start.open()
      await canceller.value

      // then
      await #expect(throws: CancellationError.self) {
        try await consumer.value
      }
      #expect(channel.suspendedReceiverCount == 0)
    }
  }

  // MARK: - Validation

  @Suite struct Validation {
    @Test func rejectsAnElementHeavierThanTheCapacity() async throws {
      // given a channel whose whole cap is smaller than the element handed to it
      let channel = BoundedAsyncChannel<Int>(capacity: 4) { element in
        element
      }

      // when / then it fails rather than waiting for a drain that could never admit it
      await #expect(
        throws: BoundedAsyncChannelError.elementExceedsCapacity(weight: 5, capacity: 4)
      ) {
        try await channel.send(5)
      }
      #expect(channel.suspendedSenderCount == 0)
    }

    @Test func rejectsANegativeWeight() async throws {
      // given a weight function that can return a negative weight
      let channel = BoundedAsyncChannel<Int>(capacity: 4) { element in
        element
      }

      // when / then
      await #expect(throws: BoundedAsyncChannelError.negativeWeight(-1)) {
        try await channel.send(-1)
      }
      #expect(channel.suspendedSenderCount == 0)
    }

    @Test func trapsOnAZeroCapacity() async {
      // given / when / then a channel that can never admit anything is a programming error
      await #expect(processExitsWith: .failure) {
        _ = BoundedAsyncChannel<Int>(capacity: 0)
      }
    }

    @Test func trapsOnANegativeCapacity() async {
      // given / when / then
      await #expect(processExitsWith: .failure) {
        _ = BoundedAsyncChannel<Int>(capacity: -1)
      }
    }

    @Test func rejectsASecondIterator() async throws {
      // given a channel whose single consumer has claimed the sequence
      let channel = BoundedAsyncChannel<Int>(capacity: 1)
      try await channel.send(1)
      var claimed = channel.makeAsyncIterator()

      // when a second consumer takes its own iterator
      var interloper = channel.makeAsyncIterator()

      // then only the claim holder may read
      await #expect(throws: BoundedAsyncChannelError.multipleIterators) {
        _ = try await interloper.next()
      }
      let received = try await claimed.next()
      #expect(received == 1)
    }
  }
}

// MARK: - Support

private struct StreamFailure: Error, Equatable {}

private func collect<Element: Sendable>(
  _ channel: BoundedAsyncChannel<Element>
) async throws -> [Element] {
  var received: [Element] = []
  for try await element in channel {
    received.append(element)
  }
  return received
}
