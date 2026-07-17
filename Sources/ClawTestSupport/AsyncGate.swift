import Synchronization

/// A latching one-shot signal for tests: `open()` releases every waiter at once, and a waiter that
/// arrives afterwards returns without suspending. Latching is what makes a gate race-free — a test
/// never has to win a scheduling race to install its waiter before the signal fires.
///
/// Lock-backed rather than an actor so `open()` is synchronous. A test's `defer` cannot `await`, and
/// every parked continuation must be resumable at teardown: a waiter stranded when a test ends turns
/// a failing assertion into a hung run.
public final class AsyncGate: Sendable {
  private struct State {
    var isOpen = false
    var nextTicket = 0
    var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Tickets whose task was cancelled before `wait` reached its registration. Consumed there, so
    /// a cancellation that arrives first is never lost and never unregisters twice.
    var cancelledTickets: Set<Int> = []
  }

  private let state = Mutex(State())

  public init() {}

  /// True once `open()` has run. Lets a caller released by cancellation tell that apart from a
  /// caller released by the signal.
  public var isOpen: Bool {
    state.withLock { current in
      current.isOpen
    }
  }

  /// Suspends until `open()`, returning immediately if the gate is already open. Returns early — and
  /// silently — if the waiting task is cancelled, so a cancelled task is never stranded on a gate
  /// that no one will open.
  public func wait() async {
    let ticket = makeTicket()
    defer { discardCancellationMarker(ticket: ticket) }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        park(ticket: ticket, continuation: continuation, honorsCancellation: true)
      }
    } onCancel: {
      releaseCancelled(ticket: ticket)
    }
  }

  /// Suspends until `open()` and ignores cancellation, wedging the caller until the gate is opened.
  /// Use it to hold a task past its own cancellation — so the code under test, not the gate, is what
  /// observes it. Always pair it with a `defer { gate.open() }` so teardown cannot strand the task.
  public func waitIgnoringCancellation() async {
    let ticket = makeTicket()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      park(ticket: ticket, continuation: continuation, honorsCancellation: false)
    }
  }

  /// Latches the gate open and resumes every waiter. Idempotent.
  public func open() {
    let pending = state.withLock { current -> [CheckedContinuation<Void, Never>] in
      current.isOpen = true
      let parked = Array(current.waiters.values)
      current.waiters.removeAll()
      return parked
    }
    for waiter in pending {
      waiter.resume()
    }
  }
}

// MARK: - Waiter bookkeeping

extension AsyncGate {
  private func makeTicket() -> Int {
    state.withLock { current in
      current.nextTicket += 1
      return current.nextTicket
    }
  }

  /// Registers `continuation` unless the gate is already open, or unless cancellation arrived first
  /// and this waiter honors it. Resumes outside the lock: resuming under it can re-enter this gate
  /// on the resumed task's thread.
  private func park(
    ticket: Int,
    continuation: CheckedContinuation<Void, Never>,
    honorsCancellation: Bool
  ) {
    let isReleased = state.withLock { current -> Bool in
      if current.isOpen {
        current.cancelledTickets.remove(ticket)
        return true
      }
      if honorsCancellation, current.cancelledTickets.remove(ticket) != nil { return true }
      current.waiters[ticket] = continuation
      return false
    }
    if isReleased { continuation.resume() }
  }

  /// Resumes a parked waiter on cancellation, or leaves a marker for a `wait` that has not reached
  /// its registration yet. Exactly one of the two paths runs, so the waiter resumes exactly once.
  private func releaseCancelled(ticket: Int) {
    let parked = state.withLock { current -> CheckedContinuation<Void, Never>? in
      guard let waiter = current.waiters.removeValue(forKey: ticket) else {
        current.cancelledTickets.insert(ticket)
        return nil
      }
      return waiter
    }
    parked?.resume()
  }

  /// Drops a marker left by a cancellation that raced a `wait` already on its way out, so a long
  /// lived gate cannot accumulate one per cancelled waiter.
  private func discardCancellationMarker(ticket: Int) {
    state.withLock { current in
      _ = current.cancelledTickets.remove(ticket)
    }
  }
}
