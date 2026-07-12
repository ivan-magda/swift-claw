import ClawCore
import Foundation

enum WatchdogRaceOutcome: Sendable {
  case runnerReturned(ContainerCommandResult)
  case deadlineExpired
  case callerCancelled
}

// MARK: - Host Watchdog Race

extension ContainerBackend {
  // First-wins race between a command runner and a host-side deadline. Both racers are
  // deliberately unstructured: a structured group would await the runner child on scope
  // exit, so a runner that never returns and ignores cancellation (a wedged container
  // process kill cannot reap) would hang the watchdog itself. After a deadline or
  // cancellation win the runner task is cancelled and abandoned, never awaited: its result
  // is meaningless once the caller fails the command closed, it is bounded by process
  // lifetime, and the shielded teardown ladder plus the prepared-image disarm own
  // containment.
  static func raceRunnerAgainstWatchdog(
    allowance: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    runner: @escaping @Sendable () async -> ContainerCommandResult
  ) async -> WatchdogRaceOutcome {
    let (outcomes, continuation) = AsyncStream.makeStream(of: WatchdogRaceOutcome.self)
    let runnerTask = Task {
      continuation.yield(.runnerReturned(await runner()))
    }

    let deadlineTask = Task {
      // A cancelled sleep must never yield: only an uncancelled, fully elapsed deadline may
      // produce .deadlineExpired, so it cannot outrace the runner's outcome after the runner
      // already won or the whole run was cancelled.
      guard (try? await sleep(allowance)) != nil else {
        return
      }
      continuation.yield(.deadlineExpired)
    }

    defer {
      runnerTask.cancel()
      deadlineTask.cancel()
    }

    for await outcome in outcomes {
      return outcome
    }
    // The stream ends without an element only when this task was cancelled mid-wait
    // (unstructured racers do not inherit that cancellation); report it explicitly so
    // the caller returns the same cancelled result the runner would have produced.
    return .callerCancelled
  }
}
