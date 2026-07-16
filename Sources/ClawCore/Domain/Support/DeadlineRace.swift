public enum DeadlineRaceOutcome<Value: Sendable>: Sendable {
  case operationReturned(Value)
  case deadlineExpired
  case callerCancelled
}

public enum DeadlineRace {
  /// First-wins race between an operation and a wall-clock deadline. Both racers are
  /// deliberately unstructured: a structured group would await the operation child on scope
  /// exit, so an operation that never returns and ignores cancellation (a wedged subprocess, a
  /// stuck system service) would hang the race itself. After a deadline or cancellation win the
  /// operation task is cancelled and ABANDONED, never awaited: its result is meaningless once
  /// the caller fails closed, and it is bounded by process lifetime.
  public static func race<Value: Sendable>(
    allowance: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    },
    operation: @escaping @Sendable () async -> Value
  ) async -> DeadlineRaceOutcome<Value> {
    let (outcomes, continuation) = AsyncStream.makeStream(of: DeadlineRaceOutcome<Value>.self)
    let operationTask = Task {
      continuation.yield(.operationReturned(await operation()))
    }

    let deadlineTask = Task {
      // A cancelled sleep must never yield: only an uncancelled, fully elapsed deadline may
      // produce .deadlineExpired, so it cannot outrace the operation's outcome after the
      // operation already won or the whole run was cancelled.
      guard (try? await sleep(allowance)) != nil else {
        return
      }
      continuation.yield(.deadlineExpired)
    }

    defer {
      operationTask.cancel()
      deadlineTask.cancel()
    }

    for await outcome in outcomes {
      return outcome
    }
    // The stream ends without an element only when this task was cancelled mid-wait
    // (unstructured racers do not inherit that cancellation); report it explicitly so the
    // caller can distinguish shutdown from a deadline.
    return .callerCancelled
  }
}
