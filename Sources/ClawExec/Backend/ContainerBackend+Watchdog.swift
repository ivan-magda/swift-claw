import ClawCore
import Foundation

enum WatchdogRaceOutcome: Sendable {
  case runnerReturned(ContainerCommandResult)
  case deadlineExpired
  case callerCancelled
}

// MARK: - Host Watchdog Race

extension ContainerBackend {
  // The shared first-wins abandonment race (ClawCore `DeadlineRace`), shaped to the watchdog's
  // vocabulary: a wedged runner is cancelled and abandoned after the deadline; the shielded
  // teardown ladder plus the prepared-image disarm own containment.
  static func raceRunnerAgainstWatchdog(
    allowance: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    runner: @escaping @Sendable () async -> ContainerCommandResult
  ) async -> WatchdogRaceOutcome {
    switch await DeadlineRace.race(allowance: allowance, sleep: sleep, operation: runner) {
    case .operationReturned(let result):
      return .runnerReturned(result)
    case .deadlineExpired:
      return .deadlineExpired
    case .callerCancelled:
      return .callerCancelled
    }
  }
}
