import Synchronization

/// The outcome of admitting a turn onto a session lane: whether the registry accepted the work or
/// is shutting down and rejected it.
public enum LaneEnqueueResult: Sendable, Equatable {
  case accepted
  case shuttingDown
}

/// The outcome of a bounded drain: every registered turn finished, or the deadline expired with the
/// listed runs still in flight.
public enum SessionLaneDrainResult: Sendable, Equatable {
  case drained
  case timedOut(activeRunIDs: [Int64])
}

/// The turn-lifecycle owner. `enqueue` atomically admits a turn and registers it on its session's
/// FIFO lane in a single actor turn, so a shutdown that races admission can never let a rejected
/// turn slip through. Each turn chains behind its session's previous turn, runs its full work
/// closure (even when cancelled, so it can self-abort its durable row), and unregisters through a
/// guaranteed finalizer. `drain` waits — up to a deadline — for every registered turn's closure to
/// return, which is what lets a graceful shutdown quiesce the lanes before tearing down resources.
public actor SessionLaneRegistry {
  private struct ActiveOperation {
    let operationID: Int64
    let runID: Int64
    let sessionID: Int64
    let task: Task<Void, Never>
  }

  private struct SessionTail {
    let operationID: Int64
    let task: Task<Void, Never>
  }

  private enum DrainSignal: Sendable {
    case drained
    case timedOut
  }

  /// The synchronous admission gate. The one lifecycle callback closes it without awaiting the
  /// actor, so a graceful shutdown stops admitting the instant it begins — even while the actor is
  /// mid-turn. `true` = open.
  private let admissionOpen = Mutex(true)

  private var accepting = true
  private var nextOperationID: Int64 = 0
  private var operations: [Int64: ActiveOperation] = [:]
  private var sessionTails: [Int64: SessionTail] = [:]
  private var drainWaiters: [CheckedContinuation<DrainSignal, Never>] = []

  public init() {}

  /// Closes the synchronous admission gate. Touches no actor state, so the lifecycle callback can
  /// reject new turns at once without hopping onto — or waiting behind — the actor.
  nonisolated public func closeAdmission() {
    admissionOpen.withLock { open in
      open = false
    }
  }

  /// Admits `work` onto `sessionID`'s FIFO lane behind whatever turn currently tails it, or rejects
  /// it when shutting down. Synchronous on the actor: the admission read and the tail registration
  /// are one uninterrupted turn, so a call that observes admission closed is always rejected and a
  /// post-close call can never be accepted. The new task cannot service its own finalize callback
  /// until this turn ends, so its operation is always registered first.
  public func enqueue(
    sessionID: Int64,
    runID: Int64,
    work: @escaping @Sendable () async -> Void
  ) -> LaneEnqueueResult {
    let admitted = admissionOpen.withLock { open in
      open
    }
    guard admitted, accepting else {
      return .shuttingDown
    }

    let operationID = nextOperationID
    nextOperationID &+= 1
    let predecessor = sessionTails[sessionID]?.task

    let task = Task {
      if let predecessor {
        // A cancelled queued turn still waits out its predecessor, then still runs its body — a turn
        // observes cancellation and self-aborts its durable row rather than being silently dropped.
        // `.value` on a non-throwing task never throws and cannot be cancelled out of the wait.
        await predecessor.value
      }
      await work()
      // Guaranteed final scope: neither the predecessor wait nor `work` can throw, so finalization
      // is always reached, including for a turn cancelled while awaiting its predecessor. This task
      // inherits the registry's isolation, so the finalize hop is a synchronous same-actor call.
      self.finalize(operationID: operationID)
    }

    operations[operationID] = ActiveOperation(
      operationID: operationID,
      runID: runID,
      sessionID: sessionID,
      task: task
    )
    sessionTails[sessionID] = SessionTail(operationID: operationID, task: task)
    return .accepted
  }

  /// Cancels every in-flight turn carrying `runID` (a durable run id is unique, so this is normally
  /// one turn). The turn still runs its body to observe the cancellation.
  public func cancel(runID: Int64) {
    for operation in operations.values where operation.runID == runID {
      operation.task.cancel()
    }
  }

  /// Cancels every in-flight turn on `sessionID` — the `/new` reset.
  public func cancelAll(sessionID: Int64) {
    for operation in operations.values where operation.sessionID == sessionID {
      operation.task.cancel()
    }
  }

  /// Stops admitting and cancels every registered turn in one actor turn — the shutdown entry.
  /// Idempotent.
  public func stopAcceptingAndCancel() {
    accepting = false
    admissionOpen.withLock { open in
      open = false
    }
    for operation in operations.values {
      operation.task.cancel()
    }
  }

  /// Waits — up to `timeout` on `clock` — for every registered turn's full work closure to return,
  /// then reports `.drained`, or `.timedOut` with the runs still in flight. Races a waiter that the
  /// finalizer resumes against a cancellation-aware deadline child; the loser is cancelled and
  /// consumed, so no deadline child or waiter continuation survives the call. Idempotent.
  public func drain<ClockType: Clock>(
    timeout: Duration,
    clock: ClockType
  ) async -> SessionLaneDrainResult where ClockType.Duration == Duration {
    if operations.isEmpty {
      return .drained
    }

    let deadline = Task {
      try? await clock.sleep(for: timeout)
      // Inherits the registry's isolation, so signalling is a synchronous same-actor call.
      self.signalDrainTimeout()
    }

    let signal = await withCheckedContinuation { continuation in
      installDrainWaiter(continuation)
    }

    // Consume the loser. If the waiter won, the deadline child is still parked on its cancellation-
    // aware sleep and returns as soon as it is cancelled; if the deadline won, it has already
    // returned. Awaiting its value leaves nothing behind.
    deadline.cancel()
    await deadline.value

    switch signal {
    case .drained:
      return .drained
    case .timedOut:
      return .timedOut(activeRunIDs: activeRunIDs())
    }
  }

  /// The run ids of every turn still registered, sorted for a stable report.
  func activeRunIDs() -> [Int64] {
    operations.values.map(\.runID).sorted()
  }
}

// MARK: - Finalization

private extension SessionLaneRegistry {
  /// Unregisters a completed turn. Compares the operation ID, never the `Task` handle or the map's
  /// emptiness: a stale completion must not clear a newer tail a later enqueue installed for the
  /// same session while this turn was still running. Resumes drain waiters once the last turn goes.
  func finalize(operationID: Int64) {
    guard let operation = operations.removeValue(forKey: operationID) else {
      return
    }
    if sessionTails[operation.sessionID]?.operationID == operationID {
      sessionTails[operation.sessionID] = nil
    }
    if operations.isEmpty {
      resumeDrainWaiters(with: .drained)
    }
  }
}

// MARK: - Drain Waiters

private extension SessionLaneRegistry {
  /// Parks a drain caller until the lanes empty, resuming it at once if they already have — the
  /// recheck closes the window between `drain`'s emptiness test and this registration.
  private func installDrainWaiter(_ continuation: CheckedContinuation<DrainSignal, Never>) {
    if operations.isEmpty {
      continuation.resume(returning: .drained)
    } else {
      drainWaiters.append(continuation)
    }
  }

  /// The deadline child's callback: resumes any still-parked waiter with `.timedOut`. A no-op once
  /// the finalizer already resumed them, since resumption takes and clears the waiters atomically.
  func signalDrainTimeout() {
    resumeDrainWaiters(with: .timedOut)
  }

  private func resumeDrainWaiters(with signal: DrainSignal) {
    let waiters = drainWaiters
    drainWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: signal)
    }
  }
}
