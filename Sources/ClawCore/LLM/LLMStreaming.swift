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

  /// 5 MiB of deltas across at most 1,024 of them, and a terminal reservation composed from the two
  /// bounds a maximal reply is charged against — the visible-text-and-tool-argument budget plus the
  /// replay-state cap — so raising either upstream bound widens the reservation with it instead of
  /// silently leaving a whole reply unable to land.
  public static let providerDefault = LLMEventBufferLimits(
    maximumDeltaCount: 1024,
    maximumDeltaBytes: 5 * 1024 * 1024,
    reservedTerminalBytes: LLMStreamLimits.maxAccumulatedContentBytes
      + LLMReplayStateBounds.maximumStateBytes
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
    let owner = LLMStreamOwner(
      channel: channel,
      resolve: { reported, isCancelRequested in
        limits.resolvedTermination(reported, isCancelRequested: isCancelRequested)
      },
      channelError: { terminal in
        guard case .failed(let failure) = terminal else { return nil }
        return failure
      }
    )
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
      lease: StreamAbandonmentLease { owner.cancel() }
    )
  }

  /// Single-consumer: a second iterator throws rather than silently splitting the stream between the
  /// two.
  public struct AsyncIterator: AsyncIteratorProtocol {
    fileprivate var base: BoundedAsyncChannel<String>.Iterator
    fileprivate let owner: LLMStreamOwner
    /// Held, never read: dropping the iterator is what the lease is here to notice.
    fileprivate let lease: StreamAbandonmentLease
    /// The terminal event sits outside the queue, so the queue running dry is not the end of the
    /// sequence. This latch is what makes it the end exactly once.
    fileprivate var isTerminalDelivered = false

    public mutating func next() async throws -> StreamEvent? {
      if let text = try await base.next() {
        return .delta(text)
      }
      guard !isTerminalDelivered else { return nil }
      isTerminalDelivered = true
      // Only a completed inference reserved one — read off the outcome the producer committed before
      // it closed the queue. A cancelled or failed stream ends without it, which is what keeps a
      // truncated reply from reading as a whole one.
      guard case .completed(let response) = owner.terminal else { return nil }
      return .finished(response)
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

  /// Settles what the producer reported against what the holder asked for and what the reservation
  /// can hold. Reads only immutable configuration, which is what lets the owner run it under its
  /// commit lock.
  func resolvedTermination(
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
    guard terminalCharge(for: response) <= reservedTerminalBytes else {
      return .failed(
        ProviderFailure(
          // Names the reservation and nothing else: the reply that overran it is the very value
          // least safe to quote.
          cause: .terminal(
            status: nil,
            message:
              "streamed reply exceeded the \(reservedTerminalBytes)-byte terminal reservation"
          ),
          accounting: .mayHaveStarted(observing: observedTokens)
        )
      )
    }
    return termination
  }
}

// MARK: - Stream ownership

/// An inference stream's owner: the shared termination machinery, settling a completed reply against
/// a pending cancellation and the terminal reservation before it commits, and closing the queue with
/// the `ProviderFailure` a `.failed` outcome carries. The reserved terminal event is derived from the
/// committed outcome rather than stored, so it is readable before the queue closes and never after.
private typealias LLMStreamOwner = StreamTerminationOwner<String, LLMStreamTermination>
