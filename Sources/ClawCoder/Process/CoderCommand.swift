import ClawCore

struct CoderCommand: Sendable {
  let executable: String
  let arguments: [String]
  let environment: [String: String]
  let workingDirectory: String
  let input: String
  let phase: CoderProcessPhase
  let timeout: Duration
}

extension CoderCommand {
  /// The time left before the job deadline, used as the next command's timeout.
  ///
  /// Throws when the task is cancelled or the deadline has passed, so no command starts without
  /// time to run.
  static func remainingTime(until deadline: ContinuousClock.Instant) throws -> Duration {
    try Task.checkCancellation()
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else {
      throw CoderGitFailure.deadline
    }
    return remaining
  }
}

struct CoderCommandResult: Sendable {
  let exitCode: Int32?
  let signal: Int32?
  let cancelled: Bool
  let timedOut: Bool
  let cleanupResolved: Bool
  let supervisionFailed: Bool
  let diagnostics: String
}

struct CoderScopedCapture: Sendable {
  let cancelled: Bool
  let timedOut: Bool
  let cleanupResolved: Bool
  let supervisionFailed: Bool
  let diagnostics: String
}

enum CoderCommandTracking: Sendable {
  case preApprovalReadOnly
  case job(record: @Sendable (_ event: CoderProcessEvent) async throws -> Void)

  func record(_ event: CoderProcessEvent) async throws {
    if case .job(let record) = self {
      try await record(event)
    }
  }
}
