import ClawCore
import ClawProcess
import Foundation

// MARK: - Typed Control Evidence

extension ContainerBackend {
  func engineRunning(deadline: ContinuousClock.Instant) async -> Bool {
    guard
      let data = await boundedCommandData(
        ContainerInvocation.systemStatus(),
        limit: Self.lifecycleCommandTimeout,
        deadline: deadline
      )
    else {
      return false
    }

    let document = try? JSONDecoder().decode(SystemStatusDocument.self, from: data)
    return document?.status == "running"
  }

  // swiftlint:disable discouraged_optional_boolean
  func containerPresent(
    _ identity: String,
    deadline: ContinuousClock.Instant
  ) async -> Bool? {
    guard
      let containers = await listedContainers(
        limit: Self.lifecycleCommandTimeout,
        deadline: deadline
      )
    else {
      return nil
    }
    return containers.contains { $0.resolvedIdentifier == identity }
  }
  // swiftlint:enable discouraged_optional_boolean

  func cidMatches(_ identity: ExecutionIdentity, at url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
      return false
    }

    let decoded = String(bytes: data, encoding: .utf8)?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    return decoded == identity.name
  }
}

// MARK: - Bounded Control Commands

extension ContainerBackend {
  /// Runs a control command clamped to the remaining deadline and returns the raw result,
  /// or nil when the deadline is already exhausted.
  func boundedCommandResult(
    _ arguments: [String],
    limit: Duration,
    deadline: ContinuousClock.Instant
  ) async -> LocalCommandResult? {
    if let timeout = clampedTimeout(limit: limit, deadline: deadline) {
      return await Self.runControlCommand(
        arguments,
        timeout: timeout,
        commands: commands,
        watchdogSleep: watchdogSleep
      )
    }
    return nil
  }

  /// Fail-closed evidence: stdout only when the command exited 0 with neither stream truncated.
  func boundedCommandData(
    _ arguments: [String],
    limit: Duration,
    deadline: ContinuousClock.Instant
  ) async -> Data? {
    if let result = await boundedCommandResult(arguments, limit: limit, deadline: deadline) {
      return Self.successOutput(of: result)
    }
    return nil
  }

  func boundedCommandSucceeded(
    _ arguments: [String],
    limit: Duration,
    deadline: ContinuousClock.Instant
  ) async -> Bool {
    await boundedCommandData(arguments, limit: limit, deadline: deadline) != nil
  }

  // swiftlint:disable discouraged_optional_collection
  func listedContainers(
    limit: Duration,
    deadline: ContinuousClock.Instant
  ) async -> [ListedContainer]? {
    if let timeout = clampedTimeout(limit: limit, deadline: deadline) {
      return await Self.fetchContainerList(
        timeout: timeout,
        commands: commands,
        watchdogSleep: watchdogSleep
      )
    }
    return nil
  }
  // swiftlint:enable discouraged_optional_collection

  // swiftlint:disable discouraged_optional_collection
  static func fetchContainerList(
    timeout: Duration,
    commands: any LocalCommandRunning,
    watchdogSleep: @escaping @Sendable (Duration) async throws -> Void
  ) async -> [ListedContainer]? {
    let result = await runControlCommand(
      ContainerInvocation.listAll(),
      timeout: timeout,
      commands: commands,
      watchdogSleep: watchdogSleep
    )

    guard let data = successOutput(of: result) else {
      return nil
    }

    return try? JSONDecoder().decode([ListedContainer].self, from: data)
  }
  // swiftlint:enable discouraged_optional_collection

  // Control commands (stop/kill/rm/list/probe/pull) get the same host-side watchdog as the
  // foreground run: the runner's own timeout is cooperative only, and a wedged control
  // command would otherwise hang the shielded cleanup ladder, the FIFO lane, or prepare().
  // The allowance is measured on a real clock (the injected `now` drives outer deadlines,
  // not this per-command bound) via the injectable sleep.
  static func runControlCommand(
    _ arguments: [String],
    timeout: Duration,
    commands: any LocalCommandRunning,
    watchdogSleep: @escaping @Sendable (Duration) async throws -> Void
  ) async -> LocalCommandResult {
    let command = LocalCommand(
      arguments: arguments,
      timeout: timeout,
      captureLimit: maxControlStreamBytes,
      teardownGracePeriod: commandTeardownGrace,
      environment: commandEnvironment
    )

    let allowance = command.timeout + command.teardownGracePeriod + hostWatchdogSlack

    switch await DeadlineRace.race(
      allowance: allowance,
      sleep: watchdogSleep,
      operation: {
        await commands.run(command)
      }
    ) {
    case .operationReturned(let result):
      return result
    case .deadlineExpired:
      return failClosedResult(.timedOut)
    case .callerCancelled:
      return failClosedResult(.cancelled)
    }
  }

  // Synthesized when the runner never reported: every consumer treats it fail-closed
  // (successOutput → nil, lifecycle/absence checks → false, bounded helpers → nil).
  private static func failClosedResult(
    _ termination: LocalCommandTermination
  ) -> LocalCommandResult {
    let empty = CapturedCommandStream(bytes: Data(), totalBytes: 0, truncated: false)
    return LocalCommandResult(
      termination: termination,
      stdout: empty,
      stderr: empty,
      processIdentifier: nil
    )
  }

  static func successOutput(of result: LocalCommandResult) -> Data? {
    guard
      case .exited(0) = result.termination,
      !result.stdout.truncated,
      !result.stderr.truncated
    else {
      return nil
    }
    return result.stdout.bytes
  }
}

private extension ContainerBackend {
  func clampedTimeout(limit: Duration, deadline: ContinuousClock.Instant) -> Duration? {
    let available = now().duration(to: deadline)

    guard available > .zero else {
      return nil
    }

    return available < limit ? available : limit
  }
}
