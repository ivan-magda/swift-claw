import Synchronization

public enum BoundedAsyncChannelError: Error, Sendable, Equatable {
  /// The channel was closed before this send was accepted; the element was never queued.
  case channelFinished
  /// The weight function returned a negative weight, which would corrupt the buffer's accounting.
  case negativeWeight(Int)
  /// The element's own weight exceeds the whole capacity, so no drain could ever admit it. Failing
  /// beats suspending a producer that could only wait forever.
  case elementExceedsCapacity(weight: Int, capacity: Int)
  /// A second iterator was requested. The channel is single-consumer: two iterators would race for
  /// each element and silently split the stream between them.
  case multipleIterators
}

/// A bounded, suspending, single-consumer channel. When the buffer is full a producer suspends until
/// the consumer drains room for it; an element is never dropped to honour the bound.
///
/// Capacity is a cap on total *weight*, not on element count, so a caller can bound a stream by what
/// it actually costs to hold — response bytes in flight, or queued event payload — with `weight`
/// defaulting to one unit per element.
///
/// Copies share one close-once state, so any copy can `send`, and any copy can `finish`. The
/// consumer side is not shareable: exactly one iterator may read the sequence.
///
/// The consumer owns teardown. Abandoning the iteration — `break`ing out of a `for try await`
/// without cancelling the consuming task — strands every parked producer forever, so such a
/// consumer must call `finish()`. Cancelling the consumer instead unwinds the producers correctly.
public struct BoundedAsyncChannel<Element: Sendable>: AsyncSequence, Sendable {
  private let storage: Storage

  /// - Parameter capacity: the greatest total weight the buffer may hold. Must be positive.
  /// - Parameter weight: the cost of one element against `capacity`. Called once per `send`, outside
  ///   the channel's lock, and must not return a negative weight. An element's weight is floored at
  ///   one: every element holds a buffer slot whatever its payload costs, so the channel bounds
  ///   element count even for a stream that weighs nothing.
  public init(
    capacity: Int,
    weight: @escaping @Sendable (Element) -> Int = { _ in 1 }
  ) {
    precondition(capacity > 0, "BoundedAsyncChannel needs a positive capacity, got \(capacity)")
    storage = Storage(capacity: capacity, weight: weight)
  }

  /// Suspends until the element is buffered, handed to a waiting consumer, or rejected.
  ///
  /// - Throws: `CancellationError` if the calling task is cancelled first — the element is not
  ///   queued; `BoundedAsyncChannelError.channelFinished` if the channel is already closed; or a
  ///   weight rejection for an element this channel could never admit.
  public func send(_ element: Element) async throws {
    try await storage.send(element)
  }

  /// Ends the sequence once every already-accepted element has been read. Later calls are ignored:
  /// the first termination wins.
  public func finish() {
    storage.close(with: .finished)
  }

  /// Ends the sequence with `error`, delivered after every already-accepted element. Later calls are
  /// ignored.
  public func finish(throwing error: any Error) {
    storage.close(with: .failed(error))
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(storage: storage, hasClaim: storage.claimIterator())
  }

  public struct Iterator: AsyncIteratorProtocol {
    fileprivate let storage: Storage
    fileprivate let hasClaim: Bool

    public mutating func next() async throws -> Element? {
      guard hasClaim else {
        throw BoundedAsyncChannelError.multipleIterators
      }
      return try await storage.receive()
    }
  }
}

// MARK: - Suspension observation

extension BoundedAsyncChannel {
  /// Producers currently suspended on a full buffer. Suspending rather than dropping is the
  /// channel's contract, so tests observe it here; production reads neither of these.
  var suspendedSenderCount: Int {
    storage.suspendedSenderCount
  }

  /// Consumers currently suspended on an empty buffer — at most one, by the single-consumer rule.
  var suspendedReceiverCount: Int {
    storage.suspendedReceiverCount
  }
}

// MARK: - Shared state

extension BoundedAsyncChannel {
  /// The one close-once state every copy of a channel shares.
  ///
  /// Locked rather than an actor: a continuation must be resumed *outside* the lock, and an actor's
  /// isolation does not survive an `await`, so the resume ordering would be unenforceable.
  fileprivate final class Storage: Sendable {
    enum Terminal {
      case finished
      case failed(any Error)
    }

    private struct Buffered {
      let element: Element
      let weight: Int
    }

    private struct ParkedSender {
      let ticket: Int
      let element: Element
      let weight: Int
      let continuation: CheckedContinuation<Void, any Error>
    }

    private struct ParkedReceiver {
      let ticket: Int
      let continuation: CheckedContinuation<Element?, any Error>
    }

    /// What a `send` must do once the lock is released.
    private enum Admission {
      case buffered
      case handedOff(CheckedContinuation<Element?, any Error>)
      case parked
      case rejected(any Error)
    }

    /// What a `receive` must do once the lock is released.
    private enum Delivery {
      case element(Element?)
      case parked
      case failed(any Error)
    }

    private struct State {
      var buffer: [Buffered] = []
      var bufferedWeight = 0
      var senders: [ParkedSender] = []
      var receivers: [ParkedReceiver] = []
      var terminal: Terminal?
      var isIteratorClaimed = false
      var nextTicket = 0
      /// Tickets whose task was cancelled before `send`/`receive` reached its registration. Consumed
      /// there, so a cancellation that arrives first neither gets lost nor unregisters twice.
      var cancelledSenderTickets: Set<Int> = []
      var cancelledReceiverTickets: Set<Int> = []

      /// Moves every parked sender whose element now fits into the buffer, in send order, and
      /// returns their continuations to resume. Stops at the first that does not fit: a stream must
      /// stay in order, so a heavy element holds the line rather than letting a lighter one pass.
      mutating func admitParkedSenders(
        capacity: Int
      ) -> [CheckedContinuation<Void, any Error>] {
        var admitted: [CheckedContinuation<Void, any Error>] = []

        while let next = senders.first, bufferedWeight + next.weight <= capacity {
          senders.removeFirst()
          buffer.append(Buffered(element: next.element, weight: next.weight))
          bufferedWeight += next.weight
          admitted.append(next.continuation)
        }

        return admitted
      }
    }

    private let state = Mutex(State())
    private let capacity: Int
    private let weight: @Sendable (Element) -> Int

    init(capacity: Int, weight: @escaping @Sendable (Element) -> Int) {
      self.capacity = capacity
      self.weight = weight
    }

    var suspendedSenderCount: Int {
      state.withLock { current in
        current.senders.count
      }
    }

    var suspendedReceiverCount: Int {
      state.withLock { current in
        current.receivers.count
      }
    }

    func claimIterator() -> Bool {
      state.withLock { current in
        if !current.isIteratorClaimed {
          current.isIteratorClaimed = true
          return true
        }
        return false
      }
    }
  }
}

// MARK: - Sending

extension BoundedAsyncChannel.Storage {
  func send(_ element: Element) async throws {
    let declaredWeight = weight(element)
    guard declaredWeight >= 0 else {
      throw BoundedAsyncChannelError.negativeWeight(declaredWeight)
    }

    let elementWeight = max(1, declaredWeight)
    guard elementWeight <= capacity else {
      throw BoundedAsyncChannelError.elementExceedsCapacity(
        weight: declaredWeight,
        capacity: capacity
      )
    }

    let ticket = makeTicket()
    defer { discardCancellationMarker(senderTicket: ticket) }

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        beginSend(
          ticket: ticket,
          element: element,
          weight: elementWeight,
          continuation: continuation
        )
      }
    } onCancel: {
      cancelSend(ticket: ticket)
    }
  }

  /// Decides this send's fate under the lock and settles it outside: a continuation resumed while
  /// the lock is held runs the woken task's next step on this thread, still holding it.
  private func beginSend(
    ticket: Int,
    element: Element,
    weight elementWeight: Int,
    continuation: CheckedContinuation<Void, any Error>
  ) {
    let admission = state.withLock { current -> Admission in
      if current.cancelledSenderTickets.remove(ticket) != nil {
        return .rejected(CancellationError())
      }

      if current.terminal != nil {
        return .rejected(BoundedAsyncChannelError.channelFinished)
      }

      if current.buffer.isEmpty, let receiver = current.receivers.first {
        current.receivers.removeFirst()
        return .handedOff(receiver.continuation)
      }

      if current.bufferedWeight + elementWeight <= capacity {
        current.buffer.append(Buffered(element: element, weight: elementWeight))
        current.bufferedWeight += elementWeight
        return .buffered
      }

      current.senders.append(
        ParkedSender(
          ticket: ticket,
          element: element,
          weight: elementWeight,
          continuation: continuation
        )
      )

      return .parked
    }

    switch admission {
    case .buffered:
      continuation.resume()
    case .handedOff(let receiver):
      receiver.resume(returning: element)
      continuation.resume()
    case .parked:
      break
    case .rejected(let error):
      continuation.resume(throwing: error)
    }
  }

  /// Unregisters a parked sender and resumes it, or marks a ticket whose registration has not landed
  /// yet. Exactly one of the two runs, so the send settles exactly once.
  private func cancelSend(ticket: Int) {
    let parked = state.withLock { current -> CheckedContinuation<Void, any Error>? in
      let index = current.senders.firstIndex { sender in
        sender.ticket == ticket
      }

      guard let index else {
        current.cancelledSenderTickets.insert(ticket)
        return nil
      }

      return current.senders.remove(at: index).continuation
    }
    parked?.resume(throwing: CancellationError())
  }
}

// MARK: - Receiving

extension BoundedAsyncChannel.Storage {
  func receive() async throws -> Element? {
    let ticket = makeTicket()
    defer {
      discardCancellationMarker(receiverTicket: ticket)
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        beginReceive(ticket: ticket, continuation: continuation)
      }
    } onCancel: {
      cancelReceive(ticket: ticket)
    }
  }

  private func beginReceive(ticket: Int, continuation: CheckedContinuation<Element?, any Error>) {
    var admitted: [CheckedContinuation<Void, any Error>] = []
    let delivery = state.withLock { current -> Delivery in
      if current.cancelledReceiverTickets.remove(ticket) != nil {
        return .failed(CancellationError())
      }

      if !current.buffer.isEmpty {
        let head = current.buffer.removeFirst()
        current.bufferedWeight -= head.weight
        admitted = current.admitParkedSenders(capacity: capacity)
        return .element(head.element)
      }

      switch current.terminal {
      case .none:
        current.receivers.append(ParkedReceiver(ticket: ticket, continuation: continuation))
        return .parked
      case .finished:
        return .element(nil)
      case .failed(let error):
        current.terminal = .finished
        return .failed(error)
      }
    }

    for sender in admitted {
      sender.resume()
    }

    switch delivery {
    case .element(let element):
      continuation.resume(returning: element)
    case .parked:
      break
    case .failed(let error):
      continuation.resume(throwing: error)
    }
  }

  private func cancelReceive(ticket: Int) {
    let parked = state.withLock { current -> CheckedContinuation<Element?, any Error>? in
      let index = current.receivers.firstIndex { receiver in
        receiver.ticket == ticket
      }

      guard let index else {
        current.cancelledReceiverTickets.insert(ticket)
        return nil
      }

      return current.receivers.remove(at: index).continuation
    }
    parked?.resume(throwing: CancellationError())
  }
}

// MARK: - Closing

extension BoundedAsyncChannel.Storage {
  /// Close-once: the first termination latches, and every waiter parked at that moment is removed
  /// and resumed exactly once. Buffered elements stay readable — closing bounds the producer, it
  /// does not discard what was already accepted.
  func close(with terminal: Terminal) {
    var wokenSenders: [CheckedContinuation<Void, any Error>] = []
    var wokenReceivers: [CheckedContinuation<Element?, any Error>] = []

    let didClose = state.withLock { current -> Bool in
      guard current.terminal == nil else {
        return false
      }
      current.terminal = terminal

      wokenSenders = current.senders.map { sender in
        sender.continuation
      }
      current.senders.removeAll()

      wokenReceivers = current.receivers.map { receiver in
        receiver.continuation
      }
      current.receivers.removeAll()

      if case .failed = terminal, !wokenReceivers.isEmpty {
        assert(
          current.buffer.isEmpty,
          "a receiver parked behind a non-empty buffer would lose this terminal failure"
        )
        current.terminal = .finished
      }
      return true
    }
    guard didClose else {
      return
    }

    for sender in wokenSenders {
      sender.resume(throwing: BoundedAsyncChannelError.channelFinished)
    }

    for receiver in wokenReceivers {
      switch terminal {
      case .finished:
        receiver.resume(returning: nil)
      case .failed(let error):
        receiver.resume(throwing: error)
      }
    }
  }
}

// MARK: - Ticketing

extension BoundedAsyncChannel.Storage {
  private func makeTicket() -> Int {
    state.withLock { current in
      current.nextTicket += 1
      return current.nextTicket
    }
  }

  /// Drops a marker left by a cancellation that raced a send already on its way out, so a long
  /// stream cannot accumulate one per cancelled producer.
  private func discardCancellationMarker(senderTicket: Int) {
    state.withLock { current in
      _ = current.cancelledSenderTickets.remove(senderTicket)
    }
  }

  private func discardCancellationMarker(receiverTicket: Int) {
    state.withLock { current in
      _ = current.cancelledReceiverTickets.remove(receiverTicket)
    }
  }
}
