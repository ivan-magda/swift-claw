import Synchronization

// MARK: - Failures

/// A provider failure paired with the one fact the runtime's accounting needs: whether the attempt
/// could already have generated tokens the owner will be billed for.
public struct ProviderFailure: Error, Sendable, Equatable {
  public let cause: ProviderError
  public let accounting: ProviderFailureAccounting

  public init(cause: ProviderError, accounting: ProviderFailureAccounting) {
    self.cause = cause
    self.accounting = accounting
  }
}

/// How a streamed inference ended. This — not the event sequence reaching its end — is the
/// authoritative outcome: a cancelled stream closes its events cleanly, so a consumer that only
/// watched the sequence could not tell a truncated reply from a whole one.
public enum LLMStreamTermination: Sendable, Equatable {
  case completed(ChatResponse)
  case failed(ProviderFailure)
  case cancelled(ProviderFailureAccounting)
}

// MARK: - Buffer limits

/// What one stream may hold in memory: a bounded delta queue, plus a reservation the terminal
/// always fits inside.
///
/// The reservation is held apart from the queue rather than inside it, which is what lets a whole
/// reply land while the queue is full — the case that matters, since a consumer that has stopped
/// draining is exactly when the terminal must still get through.
public struct LLMEventBufferLimits: Sendable, Equatable {
  public let maximumDeltaCount: Int
  public let maximumDeltaBytes: Int
  public let reservedTerminalBytes: Int

  /// - Parameter maximumDeltaCount: how many deltas may sit unread. Enforced by charging every delta
  ///   at least its share of `maximumDeltaBytes`, so both delta bounds come out of one budget.
  /// - Parameter maximumDeltaBytes: the UTF-8 payload those deltas may hold between them.
  /// - Parameter reservedTerminalBytes: what the terminal reply may weigh. A reply past it is
  ///   refused rather than held.
  public init(maximumDeltaCount: Int, maximumDeltaBytes: Int, reservedTerminalBytes: Int) {
    // Trapping rather than clamping: all three are programmer constants, so a bad one is a
    // build-time bug that shows on the first run and should say so loudly.
    precondition(maximumDeltaCount > 0, "a stream needs room for a delta, got \(maximumDeltaCount)")
    precondition(maximumDeltaBytes > 0, "a stream needs delta bytes, got \(maximumDeltaBytes)")
    precondition(
      reservedTerminalBytes > 0,
      "a stream needs a terminal reservation, got \(reservedTerminalBytes)"
    )
    self.maximumDeltaCount = maximumDeltaCount
    self.maximumDeltaBytes = maximumDeltaBytes
    self.reservedTerminalBytes = reservedTerminalBytes
  }

  /// 5 MiB of deltas across at most 1,024 of them, and another 5 MiB reserved for the terminal — 4
  /// MiB of visible text and tool arguments alongside 1 MiB of replay state.
  public static let providerDefault = LLMEventBufferLimits(
    maximumDeltaCount: 1024,
    maximumDeltaBytes: 5 * 1024 * 1024,
    reservedTerminalBytes: 5 * 1024 * 1024
  )
}

// MARK: - Event stream

/// An owning, bounded stream of inference events: the events themselves and the producer that fills
/// them. The stream owns that producer's lifetime, so joining the stream joins the inference — and
/// transitively whatever the producer nests inside itself, an HTTP exchange included.
///
/// Every consumer exit path joins — `awaitTermination()` after a full read, `cancelAndAwait()`
/// otherwise. Both ignore the joiner's own cancellation and return one cached outcome once the
/// producer has actually stopped, so a caller can rely on there being no work left behind it.
public struct LLMEventStream: AsyncSequence, Sendable {
  public typealias Element = StreamEvent

  private let channel: BoundedAsyncChannel<String>
  private let owner: LLMStreamOwner

  /// Builds a stream around `operation`, which fills the sink and reports how the inference ended.
  /// It returns without suspending, so the caller holds the cancellation-and-join handle before any
  /// authorization or network work can race a deadline.
  public static func make(
    limits: LLMEventBufferLimits = .providerDefault,
    operation: @escaping @Sendable (LLMEventSink) async -> LLMStreamTermination
  ) -> LLMEventStream {
    let channel = BoundedAsyncChannel<String>(capacity: limits.maximumDeltaBytes) { text in
      limits.deltaCharge(forTextBytes: text.utf8.count)
    }
    let owner = LLMStreamOwner(channel: channel, limits: limits)
    // A task always runs its body, even when cancelled before it starts, so `finish` always lands
    // and a join can never wait on a producer that silently never reported.
    let producer = Task {
      let termination = await operation(LLMEventSink(channel: channel))
      owner.finish(reporting: termination)
    }
    owner.attach(producer: producer)

    return LLMEventStream(channel: channel, owner: owner)
  }

  /// Stops the inference without waiting. Idempotent, and safe to call from a `deinit` or a task
  /// cancellation handler.
  public func cancel() {
    owner.cancel()
  }

  /// Stops the inference and joins it.
  public func cancelAndAwait() async -> LLMStreamTermination {
    owner.cancel()
    return await owner.awaitTermination()
  }

  /// Joins the inference, returning the one cached outcome once the producer has stopped.
  public func awaitTermination() async -> LLMStreamTermination {
    await owner.awaitTermination()
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      base: channel.makeAsyncIterator(),
      owner: owner,
      lease: LLMStreamAbandonmentLease(owner: owner)
    )
  }

  /// Single-consumer: a second iterator throws rather than silently splitting the stream between the
  /// two.
  public struct AsyncIterator: AsyncIteratorProtocol {
    fileprivate var base: BoundedAsyncChannel<String>.Iterator
    fileprivate let owner: LLMStreamOwner
    /// Held, never read: dropping the iterator is what the lease is here to notice.
    fileprivate let lease: LLMStreamAbandonmentLease
    /// The terminal event sits outside the queue, so the queue running dry is not the end of the
    /// sequence. This latch is what makes it the end exactly once.
    fileprivate var isTerminalDelivered = false

    public mutating func next() async throws -> StreamEvent? {
      if let text = try await base.next() {
        return .delta(text)
      }
      guard !isTerminalDelivered else { return nil }
      isTerminalDelivered = true
      // Only a completed inference reserved one. A cancelled or failed stream ends without it, which
      // is what keeps a truncated reply from reading as a whole one.
      return owner.reservedTerminalEvent
    }
  }
}

// MARK: - Suspension observation

extension LLMEventStream {
  /// Producers currently suspended on a full delta queue. Suspending rather than dropping is the
  /// contract, so tests observe it here; production reads neither of these.
  var suspendedDeltaSenderCount: Int {
    channel.suspendedSenderCount
  }

  /// Joiners currently parked on an undecided terminal. That they park until the producer's last act
  /// — rather than resuming the moment an outcome is known — is the contract under observation.
  var parkedJoinerCount: Int {
    owner.parkedJoinerCount
  }
}

// MARK: - Event sink

/// The write end of a stream. Deltas only: the terminal is not something a producer sends, it is
/// something a producer reports, which is what removes any window between the last event and the
/// outcome that explains it.
public struct LLMEventSink: Sendable {
  fileprivate let channel: BoundedAsyncChannel<String>

  /// Suspends until the consumer has room for `text`.
  ///
  /// - Throws: `CancellationError` or `BoundedAsyncChannelError.channelFinished` once the stream is
  ///   cancelled or its terminal has landed, or `BoundedAsyncChannelError.elementExceedsCapacity`
  ///   for a delta larger than the whole delta budget, which no amount of draining could admit.
  public func sendDelta(_ text: String) async throws {
    try await channel.send(text)
  }
}

// MARK: - Weighing

extension LLMEventBufferLimits {
  /// The least a delta may charge. Raising the floor from one byte to one slot is what makes a
  /// single byte budget carry both delta bounds: a flood of empty deltas exhausts it at the count
  /// bound, a few large ones at the byte bound.
  private var deltaSlotBytes: Int {
    max(1, maximumDeltaBytes / maximumDeltaCount)
  }

  func deltaCharge(forTextBytes textBytes: Int) -> Int {
    max(textBytes, deltaSlotBytes)
  }

  /// What holding `response` costs against the reservation: every byte a consumer can read back off
  /// it, not just the visible text, because replay state and tool arguments are held just as long.
  func terminalCharge(for response: ChatResponse) -> Int {
    var total = response.content.utf8.count
    for call in response.toolCalls {
      total = SaturatingArithmetic.sum(total, call.id.utf8.count)
      total = SaturatingArithmetic.sum(total, call.name.utf8.count)
      total = SaturatingArithmetic.sum(total, call.argumentsJSON.utf8.count)
    }
    if let state = response.providerState {
      total = SaturatingArithmetic.sum(total, state.issuer.utf8.count)
      total = SaturatingArithmetic.sum(total, state.payload.count)
    }
    return total
  }
}

// MARK: - Stream ownership

/// Cancels the stream when the iteration that held it is dropped. A consumer that breaks out of a
/// `for try await` and walks away would otherwise leave the producer parked on a full queue forever.
/// It is a backstop against that leak, not a substitute for the join: the lease stops the work, and
/// only the join reports what the work did — which is why an abandoning caller can still
/// `awaitTermination()` afterwards and read `.cancelled`.
///
/// Dropping an iterator that already read to the end cancels a producer that has finished, which
/// does nothing.
private final class LLMStreamAbandonmentLease: Sendable {
  private let owner: LLMStreamOwner

  init(owner: LLMStreamOwner) {
    self.owner = owner
  }

  deinit {
    owner.cancel()
  }
}

/// The one piece of shared state behind a stream: the producer task, the terminal outcome, the event
/// the outcome reserved, and whoever is waiting for it.
///
/// Locked rather than an actor because `cancel()` must be synchronous — a `deinit` cannot `await` —
/// and because a continuation has to be resumed outside the lock, which actor isolation could not
/// enforce across an `await`.
private final class LLMStreamOwner: Sendable {
  private struct State {
    var producer: Task<Void, Never>?
    var terminal: LLMStreamTermination?
    /// Filled by the terminal commit, in the same lock operation that caches `terminal`, so the
    /// event is readable before the queue closes and can never arrive after it.
    var terminalEvent: StreamEvent?
    var isCancelRequested = false
    var joiners: [CheckedContinuation<LLMStreamTermination, Never>] = []
  }

  /// The outcome of the one lock operation that decides a stream's fate: what it settled on, and who
  /// must be told once the queue has been closed to match.
  fileprivate struct Commit {
    let terminal: LLMStreamTermination
    let joiners: [CheckedContinuation<LLMStreamTermination, Never>]
  }

  private let state = Mutex(State())
  private let channel: BoundedAsyncChannel<String>
  private let limits: LLMEventBufferLimits

  init(channel: BoundedAsyncChannel<String>, limits: LLMEventBufferLimits) {
    self.channel = channel
    self.limits = limits
  }

  var parkedJoinerCount: Int {
    state.withLock { current in
      current.joiners.count
    }
  }

  var reservedTerminalEvent: StreamEvent? {
    state.withLock { current in
      current.terminalEvent
    }
  }

  func attach(producer: Task<Void, Never>) {
    state.withLock { current in
      current.producer = producer
    }
  }

  /// Latches the request, stops the producer, and closes the queue. Closing as well as cancelling: a
  /// producer parked on a full queue unwinds on whichever of the two reaches it first, and neither
  /// alone covers a producer that has not yet observed the other.
  ///
  /// It decides no outcome and releases no joiner — that is the producer's job, and doing it here
  /// would report the inference stopped while it was still unwinding.
  func cancel() {
    let producer = state.withLock { current -> Task<Void, Never>? in
      current.isCancelRequested = true
      return current.producer
    }
    producer?.cancel()
    channel.finish()
  }

  /// Runs once, as the producer's last act, so a resumed joiner knows the inference has stopped and
  /// every transfer nested inside it with it.
  func finish(reporting termination: LLMStreamTermination) {
    guard let commit = commit(termination) else { return }
    // Caching before closing is what resolves the terminal-versus-cancellation race: a consumer that
    // sees the queue end can always read the reserved event that a completed commit had already put
    // there, so the outcome — never the timing of the last event — decides what it saw.
    close(for: commit.terminal)
    for joiner in commit.joiners {
      joiner.resume(returning: commit.terminal)
    }
  }

  /// Deliberately without a cancellation handler: a join reports what the producer did, and a
  /// joiner's own cancellation must not fabricate an answer before the producer has stopped.
  func awaitTermination() async -> LLMStreamTermination {
    await withCheckedContinuation { continuation in
      park(continuation)
    }
  }
}

// MARK: - Terminal commit

private extension LLMStreamOwner {
  /// The one lock operation that linearizes a stream's terminal. It reserves the event, caches the
  /// outcome, and hands back the joiners to resume once the queue has been closed to match. A
  /// cancellation that took the lock first wins here; one that takes it afterwards finds the outcome
  /// latched and changes nothing.
  ///
  /// Returns nil for a second report, which is how the first outcome stays the only one.
  func commit(_ termination: LLMStreamTermination) -> Commit? {
    state.withLock { current -> Commit? in
      guard current.terminal == nil else { return nil }
      let decided = resolve(termination, isCancelRequested: current.isCancelRequested)
      if case .completed(let response) = decided {
        current.terminalEvent = Self.terminalEvent(for: response)
      }
      current.terminal = decided
      let parked = current.joiners
      current.joiners.removeAll()
      return Commit(terminal: decided, joiners: parked)
    }
  }

  /// Settles what the producer reported against what the holder asked for and what the reservation
  /// can hold.
  ///
  /// Reads only immutable configuration, which is what lets `commit` call it with the lock held.
  func resolve(
    _ termination: LLMStreamTermination,
    isCancelRequested: Bool
  ) -> LLMStreamTermination {
    guard case .completed(let response) = termination else {
      // A failure keeps the typed cause the producer gave it even against a racing cancellation:
      // the producer knows why it stopped, and a join must not erase that.
      return termination
    }
    let observedTokens = response.usage?.completionTokens ?? 0
    if isCancelRequested {
      return .cancelled(.mayHaveStarted(observing: observedTokens))
    }
    guard limits.terminalCharge(for: response) <= limits.reservedTerminalBytes else {
      return .failed(
        ProviderFailure(
          // Names the reservation and nothing else: the reply that overran it is the very value
          // least safe to quote.
          cause: .terminal(
            status: nil,
            message:
              "streamed reply exceeded the \(limits.reservedTerminalBytes)-byte terminal reservation"
          ),
          accounting: .mayHaveStarted(observing: observedTokens)
        )
      )
    }
    return termination
  }

  static func terminalEvent(for response: ChatResponse) -> StreamEvent {
    .finished(response)
  }

  func close(for terminal: LLMStreamTermination) {
    switch terminal {
    case .completed, .cancelled:
      channel.finish()
    case .failed(let failure):
      channel.finish(throwing: failure)
    }
  }
}

// MARK: - Joining

private extension LLMStreamOwner {
  /// Resumes outside the lock: resuming under it would run the woken task's next step on this
  /// thread while the lock is still held.
  func park(_ continuation: CheckedContinuation<LLMStreamTermination, Never>) {
    let cached = state.withLock { current -> LLMStreamTermination? in
      if let terminal = current.terminal { return terminal }
      current.joiners.append(continuation)
      return nil
    }
    if let cached {
      continuation.resume(returning: cached)
    }
  }
}
