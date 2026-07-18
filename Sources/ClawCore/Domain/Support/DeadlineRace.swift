public enum DeadlineRaceOutcome<Value: Sendable>: Sendable {
  case operationReturned(Value)
  case deadlineExpired
  case callerCancelled
}

public enum DeadlineRace {
  public static func race<Value: Sendable>(
    allowance: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    },
    operation: @escaping @Sendable () async -> Value
  ) async -> DeadlineRaceOutcome<Value> {
    let (outcomes, continuation) = AsyncStream.makeStream(
      of: DeadlineRaceOutcome<Value>.self
    )

    let operationTask = Task {
      continuation.yield(.operationReturned(await operation()))
    }

    let deadlineTask = Task {
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

    return .callerCancelled
  }
}
