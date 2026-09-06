import Synchronization

// MARK: - Abandonment lease

/// Runs its teardown when the iteration that held it is dropped. A consumer that breaks out of a
/// `for try await` and walks away would otherwise leave the producer parked on a full buffer forever.
/// It is a backstop against that leak, not a substitute for the join: the lease stops the work, and
/// only the join reports what the work did — which is why an abandoning caller can still await the
/// termination afterwards and read `.cancelled`.
///
/// Dropping an iterator that already read to the end runs teardown against a producer that has
/// finished, which does nothing.
final class StreamAbandonmentLease: Sendable {
  private let onAbandon: @Sendable () -> Void

  init(_ onAbandon: @escaping @Sendable () -> Void) {
    self.onAbandon = onAbandon
  }

  deinit {
    onAbandon()
  }
}

// MARK: - Termination owner

/// The shared state behind an owning, bounded stream: the producer task, the terminal outcome once
/// the producer commits it, and whoever is parked waiting for it. One instance backs both an HTTP
/// body transfer and an inference event stream; the two differ only in how a reported termination is
/// settled against a pending cancellation and how the channel is closed to match, which arrive as the
/// two closures.
///
/// Locked rather than an actor because `cancel()` must be synchronous — a `deinit` cannot `await` —
/// and because a continuation has to be resumed outside the lock, which actor isolation could not
/// enforce across an `await`.
final class StreamTerminationOwner<Element: Sendable, Termination: Sendable>: Sendable {
  private struct State {
    var producer: Task<Void, Never>?
    var terminal: Termination?
    var isCancelRequested = false
    var joiners: [CheckedContinuation<Termination, Never>] = []
  }

  /// The outcome of the one lock operation that decides a stream's fate: what it settled on, and who
  /// must be told once the channel has been closed to match.
  fileprivate struct Commit {
    let terminal: Termination
    let joiners: [CheckedContinuation<Termination, Never>]
  }

  private let state = Mutex(State())
  private let channel: BoundedAsyncChannel<Element>
  /// Settles what the producer reported against a pending cancellation and whatever else the
  /// consumer's policy weighs. Reads only immutable configuration, so `commit` runs it under the lock.
  private let resolve: @Sendable (Termination, _ isCancelRequested: Bool) -> Termination
  /// The error the decided terminal closes the channel with, or nil to close it cleanly.
  private let channelError: @Sendable (Termination) -> (any Error)?

  init(
    channel: BoundedAsyncChannel<Element>,
    resolve: @escaping @Sendable (Termination, Bool) -> Termination,
    channelError: @escaping @Sendable (Termination) -> (any Error)?
  ) {
    self.channel = channel
    self.resolve = resolve
    self.channelError = channelError
  }

  /// The decided outcome once the producer has committed it, else nil. A consumer derives whatever it
  /// reserves off a completed terminal from this: the outcome is cached in the same lock operation
  /// that decides it, so it is readable before the channel closes and can never arrive after it.
  var terminal: Termination? {
    state.withLock { current in
      current.terminal
    }
  }

  var parkedJoinerCount: Int {
    state.withLock { current in
      current.joiners.count
    }
  }

  func attach(producer: Task<Void, Never>) {
    state.withLock { current in
      current.producer = producer
    }
  }

  /// Latches the request, stops the producer, and closes the channel. Closing as well as cancelling:
  /// a producer parked on a full buffer unwinds on whichever of the two reaches it first, and neither
  /// alone covers a producer that has not yet observed the other.
  ///
  /// It decides no outcome and releases no joiner — that is the producer's job, and doing it here
  /// would report the transfer stopped while it was still unwinding.
  func cancel() {
    let producer = state.withLock { current -> Task<Void, Never>? in
      current.isCancelRequested = true
      return current.producer
    }
    producer?.cancel()
    channel.finish()
  }

  /// Runs once, as the producer's last act, so a resumed joiner knows the transfer has stopped and
  /// every transfer nested inside it with it.
  func finish(reporting termination: Termination) {
    guard let commit = commit(termination) else {
      return
    }
    // Caching before closing is what resolves the terminal-versus-cancellation race: a consumer that
    // sees the channel end can always read whatever a completed commit reserved before the close, so
    // the outcome — never the timing of the last element — decides what it saw.
    close(for: commit.terminal)
    for joiner in commit.joiners {
      joiner.resume(returning: commit.terminal)
    }
  }

  /// Deliberately without a cancellation handler: a join reports what the producer did, and a
  /// joiner's own cancellation must not fabricate an answer before the producer has stopped.
  func awaitTermination() async -> Termination {
    await withCheckedContinuation { continuation in
      park(continuation)
    }
  }
}

// MARK: - Terminal commit

private extension StreamTerminationOwner {
  /// The one lock operation that linearizes a stream's terminal. It settles the outcome, caches it,
  /// and hands back the joiners to resume once the channel has been closed to match. A cancellation
  /// that took the lock first wins here; one that takes it afterwards finds the outcome latched and
  /// changes nothing.
  ///
  /// Returns nil for a second report, which is how the first outcome stays the only one.
  func commit(_ termination: Termination) -> Commit? {
    state.withLock { current -> Commit? in
      guard current.terminal == nil else {
        return nil
      }
      let decided = resolve(termination, current.isCancelRequested)
      current.terminal = decided
      let parked = current.joiners
      current.joiners.removeAll()
      return Commit(terminal: decided, joiners: parked)
    }
  }

  func close(for terminal: Termination) {
    if let error = channelError(terminal) {
      channel.finish(throwing: error)
    } else {
      channel.finish()
    }
  }

  /// Resumes outside the lock: resuming under it would run the woken task's next step on this thread
  /// while the lock is still held.
  func park(_ continuation: CheckedContinuation<Termination, Never>) {
    let cached = state.withLock { current -> Termination? in
      if let terminal = current.terminal { return terminal }
      current.joiners.append(continuation)
      return nil
    }
    if let cached {
      continuation.resume(returning: cached)
    }
  }
}
