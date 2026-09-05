import ClawCore
import ClawProcess
import Foundation

public actor ContainerBackend {
  /// Absolute path of the Apple `container` CLI this backend drives.
  public static let cliPath = "/usr/local/bin/container"

  /// Ambient host values the container CLI must never receive: a forwarded agent socket, and
  /// two knobs that would rewrite how the sandbox itself launches.
  static let commandEnvironment = LocalCommandEnvironment.inherit(
    removingKeys: [
      "SSH_AUTH_SOCK",
      "CONTAINER_DEBUG",
      "CONTAINER_DEFAULT_PLATFORM",
    ]
  )

  public static let maxRawStreamBytes = LocalCommandLimits.maxRawStreamBytes
  public static let maxControlStreamBytes = 1024 * 1024

  public static let teardownAllowance: Duration = .seconds(20)
  public static let lifecycleCommandTimeout: Duration = .seconds(5)
  public static let ordinaryCommandTimeout: Duration = .seconds(15)
  public static let pullTimeout: Duration = .seconds(120)
  public static let prepareTimeout: Duration = .seconds(300)
  static let commandTeardownGrace = LocalCommandLimits.teardownGracePeriod
  // Head start the host watchdog grants the runner's own timeout + teardown, so in the
  // cooperative case the runner always reports its typed outcome before the watchdog fires.
  static let hostWatchdogSlack: Duration = .seconds(2)

  let settings: ExecSandboxSettings
  let stateRoot: URL
  let commands: any LocalCommandRunning

  let sanitizeReason: @Sendable (String) -> String
  let now: @Sendable () -> ContinuousClock.Instant
  let supportedHost: @Sendable () -> Bool
  let executionAdmitted: @Sendable () -> Void
  // Drives the host-watchdog deadline sleeps; injectable so tests can fire a watchdog
  // without waiting out a real per-command allowance.
  let watchdogSleep: @Sendable (Duration) async throws -> Void
  // Longest-first so nested paths are replaced before the roots that contain them.
  let sensitiveHostPaths: [String]

  var preparedInitImage: String?
  var executionTail: Task<ExecutionResult, Never>?
  var executionTasks: [UUID: Task<ExecutionResult, Never>] = [:]
  var cleanupTasks: [UUID: Task<Bool, Never>] = [:]
  var shuttingDown = false

  public init(
    settings: ExecSandboxSettings,
    stateRoot: URL,
    commands: any LocalCommandRunning,
    sanitizeReason: @escaping @Sendable (String) -> String,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.init(
      settings: settings,
      stateRoot: stateRoot,
      commands: commands,
      sanitizeReason: sanitizeReason,
      now: now,
      supportedHost: Self.defaultSupportedHost,
      executionAdmitted: {}
    )
  }

  init(
    settings: ExecSandboxSettings,
    stateRoot: URL,
    commands: any LocalCommandRunning,
    sanitizeReason: @escaping @Sendable (String) -> String,
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    supportedHost: @escaping @Sendable () -> Bool,
    executionAdmitted: @escaping @Sendable () -> Void = {},
    watchdogSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.settings = settings
    self.stateRoot = stateRoot
    self.commands = commands

    self.sanitizeReason = sanitizeReason
    self.now = now
    self.supportedHost = supportedHost
    self.executionAdmitted = executionAdmitted
    self.watchdogSleep = watchdogSleep

    self.sensitiveHostPaths = [
      stateRoot.path,
      stateRoot.appending(path: ScratchWorkspace.scratchRootName).path,
      FileManager.default.homeDirectoryForCurrentUser.path,
      Self.cliPath,
    ]
    .filter { !$0.isEmpty }
    .sorted { $0.count > $1.count }
  }

  public func versionAvailability() async -> BackendAvailability {
    guard supportedHost() else {
      return .unavailable(
        reason: ownerSafe("execute_code requires macOS 26 or newer on arm64")
      )
    }

    let deadline = now().advanced(by: Self.ordinaryCommandTimeout)
    guard
      let data = await boundedCommandData(
        ContainerInvocation.systemVersion(),
        limit: Self.ordinaryCommandTimeout,
        deadline: deadline
      )
    else {
      return .unavailable(reason: ownerSafe("container version command failed"))
    }

    guard
      let documents = try? JSONDecoder().decode([SystemVersionDocument].self, from: data),
      let cli = documents.first(where: { $0.appName == "container" })
    else {
      return .unavailable(reason: ownerSafe("container version response was invalid"))
    }

    guard let version = SemanticVersion(cli.version) else {
      return .unavailable(reason: ownerSafe("container CLI version was malformed"))
    }

    guard version >= ExecSandboxSettings.minimumContainerVersion else {
      return .unavailable(
        reason: ownerSafe(
          "container CLI \(cli.version) is older than the required 1.0.0"
        )
      )
    }

    return .available(engineVersion: cli.version)
  }

  public func probe() async -> BackendAvailability {
    guard supportedHost() else {
      return .unavailable(
        reason: ownerSafe("execute_code requires macOS 26 or newer on arm64")
      )
    }

    let deadline = now().advanced(by: Self.ordinaryCommandTimeout)
    guard
      let data = await boundedCommandData(
        ContainerInvocation.systemStatus(),
        limit: Self.ordinaryCommandTimeout,
        deadline: deadline
      ),
      let status = try? JSONDecoder().decode(SystemStatusDocument.self, from: data),
      status.status == "running"
    else {
      return .unavailable(reason: ownerSafe("container engine is not running"))
    }

    return await versionAvailability()
  }

  public func run(_ request: ExecutionRequest) async -> ExecutionResult {
    guard let initImage = preparedInitImage else {
      return unavailableResult("sandbox is not prepared")
    }

    return await enqueueExecution { [weak self] in
      guard let self else {
        return Self.cancelledResult()
      }
      return await self.performExecution(request, initImage: initImage)
    }
  }

  func setPreparedInitImageForTesting(_ image: String?) {
    preparedInitImage = image
  }
}

// MARK: - Results and Reason Boundary

extension ContainerBackend {
  func result(
    _ termination: ExecTermination
  ) -> ExecutionResult {
    ExecutionResult(
      terminationReason: termination,
      stdout: "",
      stderr: "",
      truncatedRawBytes: false
    )
  }

  func unavailableResult(_ reason: String) -> ExecutionResult {
    ExecutionResult(
      terminationReason: .unavailable(reason: ownerSafe(reason)),
      stdout: "",
      stderr: "",
      truncatedRawBytes: false
    )
  }

  func infrastructureResult(
    _ reason: String
  ) -> ExecutionResult {
    result(.startFailed(reason: ownerSafe(reason)))
  }

  func ownerSafe(_ reason: String) -> String {
    var safe = sanitizeReason(reason)

    for path in sensitiveHostPaths {
      safe = safe.replacingOccurrences(of: path, with: "[HOST_PATH]")
    }

    return safe
  }
}
