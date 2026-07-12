import ClawCore
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public actor ContainerBackend {
  public static let maxRawStreamBytes = 1024 * 1024
  public static let maxControlStreamBytes = 1024 * 1024

  public static let teardownAllowance: Duration = .seconds(20)
  public static let lifecycleCommandTimeout: Duration = .seconds(5)
  public static let ordinaryCommandTimeout: Duration = .seconds(15)
  public static let pullTimeout: Duration = .seconds(120)
  public static let prepareTimeout: Duration = .seconds(300)
  static let commandTeardownGrace: Duration = .seconds(2)
  // Head start the host watchdog grants the runner's own timeout + teardown, so in the
  // cooperative case the runner always reports its typed outcome before the watchdog fires.
  static let hostWatchdogSlack: Duration = .seconds(2)

  let settings: ExecSandboxSettings
  let stateRoot: URL
  let commands: any ContainerCommandRunning
  let sanitizeReason: @Sendable (String) -> String
  let now: @Sendable () -> ContinuousClock.Instant
  let supportedHost: @Sendable () -> Bool
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
    commands: any ContainerCommandRunning,
    sanitizeReason: @escaping @Sendable (String) -> String,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.init(
      settings: settings,
      stateRoot: stateRoot,
      commands: commands,
      sanitizeReason: sanitizeReason,
      now: now,
      supportedHost: Self.defaultSupportedHost
    )
  }

  init(
    settings: ExecSandboxSettings,
    stateRoot: URL,
    commands: any ContainerCommandRunning,
    sanitizeReason: @escaping @Sendable (String) -> String,
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    supportedHost: @escaping @Sendable () -> Bool,
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
    self.watchdogSleep = watchdogSleep
    self.sensitiveHostPaths = [
      stateRoot.path,
      stateRoot.appending(path: ScratchWorkspace.scratchRootName).path,
      FileManager.default.homeDirectoryForCurrentUser.path,
      "/usr/local/bin/container",
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

  var queuedExecutionCountForTesting: Int {
    executionTasks.count
  }

  func runSerializedForTesting(
    operation: @escaping @Sendable () async -> ExecutionResult
  ) async -> ExecutionResult {
    await enqueueExecution(operation: operation)
  }
}

// MARK: - Serialized Execution

private extension ContainerBackend {
  func enqueueExecution(
    operation: @escaping @Sendable () async -> ExecutionResult
  ) async -> ExecutionResult {
    guard !shuttingDown, !Task.isCancelled else {
      return Self.cancelledResult()
    }

    let prior = executionTail
    let taskIdentifier = UUID()
    let work = Task<ExecutionResult, Never> {
      _ = await prior?.value

      guard !Task.isCancelled else {
        return Self.cancelledResult()
      }

      return await operation()
    }
    executionTasks[taskIdentifier] = work
    executionTail = work

    let result = await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
    executionTasks[taskIdentifier] = nil

    return result
  }

  static func cancelledResult() -> ExecutionResult {
    ExecutionResult(
      terminationReason: .cancelled,
      stdout: "",
      stderr: "",
      truncatedRawBytes: false,
      wallClock: .zero
    )
  }

  nonisolated static func defaultSupportedHost() -> Bool {
    #if os(macOS) && arch(arm64)
      ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    #else
      false
    #endif
  }
}

// MARK: - Execution Pipeline

private extension ContainerBackend {
  func performExecution(_ request: ExecutionRequest, initImage: String) async -> ExecutionResult {
    // A prior run in the FIFO lane may have disarmed the backend after this run was admitted
    // (its cleanup could not confirm container removal). The disarm happens before that run
    // returns and this run only dequeues afterwards, so re-checking here — ignoring the
    // initImage captured at admission — guarantees a queued run never boots a VM beside the
    // surviving container.
    guard preparedInitImage != nil else {
      return unavailableResult("sandbox is not prepared")
    }

    let started = now()
    let deadline = started.advanced(by: request.timeout + Self.teardownAllowance)
    let identity = ExecutionIdentity()
    let workspace: ScratchWorkspace

    do {
      workspace = try ScratchWorkspace.create(
        stateRoot: stateRoot,
        identity: identity,
        request: request
      )
    } catch {
      return infrastructureResult(
        "failed to materialize execution scratch: \(error)",
        started: started
      )
    }

    let command = ContainerCommand(
      arguments: ContainerInvocation.run(
        identity: identity,
        scratchPath: workspace.directory.path,
        cidFilePath: workspace.cidFile.path,
        language: request.language,
        network: request.network,
        settings: settings,
        initImage: initImage
      ),
      timeout: request.timeout,
      captureLimit: Self.maxRawStreamBytes,
      teardownGracePeriod: Self.commandTeardownGrace
    )

    var result =
      switch await boundedForegroundRun(command, deadline: deadline) {
      case .runnerReturned(let commandResult):
        await classify(
          commandResult,
          identity: identity,
          cidFile: workspace.cidFile,
          deadline: deadline,
          started: started
        )
      case .deadlineExpired:
        self.result(.timedOutKilled, started: started)
      case .callerCancelled:
        self.result(.cancelled, started: started)
      }

    let cleanupOK = await runShieldedCleanup(
      identity: identity,
      workspace: workspace
    )
    if !cleanupOK {
      // The container provably survived the teardown ladder; fail closed and refuse new
      // admissions until a future successful prepare() reaps it, otherwise the next queued
      // run would boot a second VM beside the zombie.
      preparedInitImage = nil
      result = infrastructureResult(
        "could not confirm container removal for \(identity.name)",
        started: started
      )
    }

    return result
  }

  // The runner enforces the guest timeout itself; this host-side watchdog is an independent
  // bound so a wedged `container run` that never returns cannot hang the execution lane.
  func boundedForegroundRun(
    _ command: ContainerCommand,
    deadline: ContinuousClock.Instant
  ) async -> WatchdogRaceOutcome {
    let commands = commands
    let remaining = now().duration(to: deadline)

    return await Self.raceRunnerAgainstWatchdog(
      allowance: remaining,
      sleep: watchdogSleep
    ) {
      await commands.run(command)
    }
  }

  func classify(
    _ commandResult: ContainerCommandResult,
    identity: ExecutionIdentity,
    cidFile: URL,
    deadline: ContinuousClock.Instant,
    started: ContinuousClock.Instant
  ) async -> ExecutionResult {
    switch commandResult.termination {
    case .timedOut:
      return result(.timedOutKilled, started: started)
    case .cancelled:
      return result(.cancelled, started: started)
    case .startFailed(let reason):
      return infrastructureResult(reason, started: started)
    case .signaled(let signal):
      return infrastructureResult(
        "container CLI was terminated by host signal \(signal)",
        started: started
      )
    case .exited(let code):
      guard cidMatches(identity, at: cidFile) else {
        return infrastructureResult(
          "container did not create its identity file",
          started: started
        )
      }

      guard await engineRunning(deadline: deadline) else {
        return infrastructureResult(
          "container engine became unavailable after execution",
          started: started
        )
      }

      guard let present = await containerPresent(identity.name, deadline: deadline) else {
        return infrastructureResult(
          "could not inspect container state after execution",
          started: started
        )
      }

      guard !present else {
        return infrastructureResult(
          "container remained after the foreground CLI exited",
          started: started
        )
      }

      return ExecutionResult(
        terminationReason: .exited(code: code),
        stdout: String(decoding: commandResult.stdout.bytes, as: UTF8.self),
        stderr: String(decoding: commandResult.stderr.bytes, as: UTF8.self),
        truncatedRawBytes: commandResult.stdout.truncated || commandResult.stderr.truncated,
        wallClock: started.duration(to: now())
      )
    }
  }
}

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

// MARK: - Shielded Cleanup

extension ContainerBackend {
  func runShieldedCleanup(
    identity: ExecutionIdentity,
    workspace: ScratchWorkspace
  ) async -> Bool {
    let commands = commands
    let watchdogSleep = watchdogSleep
    let taskIdentifier = UUID()

    let cleanup = Task.detached {
      await CleanupOperation(
        commands: commands,
        identity: identity.name,
        workspace: workspace,
        watchdogSleep: watchdogSleep
      ).run()
    }

    cleanupTasks[taskIdentifier] = cleanup
    let succeeded = await cleanup.value
    cleanupTasks[taskIdentifier] = nil

    return succeeded
  }
}

private struct CleanupOperation: Sendable {
  let commands: any ContainerCommandRunning
  let identity: String
  let workspace: ScratchWorkspace
  let watchdogSleep: @Sendable (Duration) async throws -> Void

  // The teardown ladder is shielded from cancellation and each command keeps its own
  // `lifecycleCommandTimeout` independent of the run's outer deadline, so a wedged or cancelled
  // execution still tears its VM down instead of orphaning it (ARCHITECTURE.md §13 return bound).
  func run() async -> Bool {
    for step in ContainerInvocation.teardownLadder(identity) {
      _ = await runLifecycle(step)
    }

    let absent = await finalAbsence()

    do {
      try workspace.remove()
    } catch {
      return false
    }

    return absent
  }

  private func runLifecycle(_ arguments: [String]) async -> Bool {
    let result = await ContainerBackend.runControlCommand(
      arguments,
      timeout: ContainerBackend.lifecycleCommandTimeout,
      commands: commands,
      watchdogSleep: watchdogSleep
    )
    return ContainerBackend.successOutput(of: result) != nil
  }

  // Cleanup deliberately keeps the full per-command timeout (not the run's outer deadline,
  // which may already be exhausted) so a wedged execution still gets its teardown attempts.
  private func finalAbsence() async -> Bool {
    guard
      let containers = await ContainerBackend.fetchContainerList(
        timeout: ContainerBackend.lifecycleCommandTimeout,
        commands: commands,
        watchdogSleep: watchdogSleep
      )
    else {
      return false
    }
    return !containers.contains { $0.resolvedIdentifier == identity }
  }
}

// MARK: - Typed Control Evidence

private extension ContainerBackend {
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

  func cidMatches(_ identity: ExecutionIdentity, at url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
      return false
    }

    let decoded = String(decoding: data, as: UTF8.self).trimmingCharacters(
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
  ) async -> ContainerCommandResult? {
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

  static func fetchContainerList(
    timeout: Duration,
    commands: any ContainerCommandRunning,
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

  // Control commands (stop/kill/rm/list/probe/pull) get the same host-side watchdog as the
  // foreground run: the runner's own timeout is cooperative only, and a wedged control
  // command would otherwise hang the shielded cleanup ladder, the FIFO lane, or prepare().
  // The allowance is measured on a real clock (the injected `now` drives outer deadlines,
  // not this per-command bound) via the injectable sleep.
  static func runControlCommand(
    _ arguments: [String],
    timeout: Duration,
    commands: any ContainerCommandRunning,
    watchdogSleep: @escaping @Sendable (Duration) async throws -> Void
  ) async -> ContainerCommandResult {
    let command = ContainerCommand(
      arguments: arguments,
      timeout: timeout,
      captureLimit: maxControlStreamBytes,
      teardownGracePeriod: commandTeardownGrace
    )

    let clock = ContinuousClock()
    let started = clock.now
    let allowance = command.timeout + command.teardownGracePeriod + hostWatchdogSlack

    switch await raceRunnerAgainstWatchdog(
      allowance: allowance,
      sleep: watchdogSleep,
      runner: {
        await commands.run(command)
      }
    ) {
    case .runnerReturned(let result):
      return result
    case .deadlineExpired:
      return failClosedResult(.timedOut, wallClock: started.duration(to: clock.now))
    case .callerCancelled:
      return failClosedResult(.cancelled, wallClock: started.duration(to: clock.now))
    }
  }

  // Synthesized when the runner never reported: every consumer treats it fail-closed
  // (successOutput → nil, lifecycle/absence checks → false, bounded helpers → nil).
  private static func failClosedResult(
    _ termination: ContainerCommandTermination,
    wallClock: Duration
  ) -> ContainerCommandResult {
    let empty = CapturedCommandStream(bytes: Data(), totalBytes: 0, truncated: false)
    return ContainerCommandResult(
      termination: termination,
      stdout: empty,
      stderr: empty,
      processIdentifier: nil,
      wallClock: wallClock
    )
  }

  static func successOutput(of result: ContainerCommandResult) -> Data? {
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

private struct SystemStatusDocument: Decodable {
  let status: String
}

// All four fields stay required even though only appName/version drive the gate: decoding pins
// the expected v1.1.0 CLI row shape and rejects unrelated {appName, version} payloads from a
// different command.
private struct SystemVersionDocument: Decodable {
  let version: String
  let buildType: String
  let commit: String
  let appName: String
}

struct ListedContainer: Decodable, Sendable {
  struct Configuration: Decodable, Sendable {
    let id: String?
    let labels: [String: String]?
  }

  let id: String?
  let configuration: Configuration?

  var resolvedIdentifier: String? {
    id ?? configuration?.id
  }

  var labels: [String: String] {
    configuration?.labels ?? [:]
  }
}

// MARK: - Results and Reason Boundary

extension ContainerBackend {
  func result(
    _ termination: ExecTermination,
    started: ContinuousClock.Instant
  ) -> ExecutionResult {
    ExecutionResult(
      terminationReason: termination,
      stdout: "",
      stderr: "",
      truncatedRawBytes: false,
      wallClock: started.duration(to: now())
    )
  }

  func unavailableResult(_ reason: String) -> ExecutionResult {
    ExecutionResult(
      terminationReason: .unavailable(reason: ownerSafe(reason)),
      stdout: "",
      stderr: "",
      truncatedRawBytes: false,
      wallClock: .zero
    )
  }

  func infrastructureResult(
    _ reason: String,
    started: ContinuousClock.Instant
  ) -> ExecutionResult {
    result(.startFailed(reason: ownerSafe(reason)), started: started)
  }

  func ownerSafe(_ reason: String) -> String {
    var safe = sanitizeReason(reason)
    for path in sensitiveHostPaths {
      safe = safe.replacingOccurrences(of: path, with: "[HOST_PATH]")
    }
    return safe
  }
}

enum ScratchWorkspaceError: Error, Equatable {
  case invalidRequest(String)
  case fileSystem(String)
}

struct ScratchWorkspace: Sendable {
  static let scratchRootName = "exec-scratch"
  static let controlRootName = "exec-control"

  static let maxEntrypointBytes = 16 * 1024
  static let maxInputBytes = 1024 * 1024
  static let maxInputTotalBytes = 4 * 1024 * 1024
  static let maxInputFiles = 16

  let scratchRoot: URL
  let controlRoot: URL
  let directory: URL
  let cidFile: URL

  static func create(
    stateRoot: URL,
    identity: ExecutionIdentity,
    request: ExecutionRequest
  ) throws -> ScratchWorkspace {
    try validate(request)

    let scratchRoot = stateRoot.appending(path: scratchRootName, directoryHint: .isDirectory)
    let controlRoot = stateRoot.appending(path: controlRootName, directoryHint: .isDirectory)
    let directory = scratchRoot.appending(path: identity.identifier, directoryHint: .isDirectory)
    // This directory becomes the source of a `--mount type=bind,source=…` directive, whose
    // comma/equals grammar has no escape syntax in apple/container 1.1.0; a delimiter in the
    // path would be parsed as extra directive fields, so refuse it before creating anything.
    guard !directory.path.contains(","), !directory.path.contains("=") else {
      throw ScratchWorkspaceError.invalidRequest(
        "state root path contains characters that cannot cross a mount directive"
      )
    }

    try ensurePrivateDirectory(scratchRoot)
    try ensurePrivateDirectory(controlRoot)

    guard directory.path.withCString({ mkdir($0, 0o700) }) == 0 else {
      throw ScratchWorkspaceError.fileSystem("cannot create execution scratch")
    }

    let workspace = ScratchWorkspace(
      scratchRoot: scratchRoot,
      controlRoot: controlRoot,
      directory: directory,
      cidFile: controlRoot.appending(path: "\(identity.identifier).cid")
    )

    do {
      try write(request.entrypoint, in: directory)

      for input in request.inputs {
        try write(input, in: directory)
      }

      return workspace
    } catch {
      try? workspace.remove()
      throw error
    }
  }

  func remove() throws {
    let manager = FileManager.default

    if manager.fileExists(atPath: directory.path) {
      try manager.removeItem(at: directory)
    }

    if manager.fileExists(atPath: cidFile.path) {
      try manager.removeItem(at: cidFile)
    }
  }
}

// MARK: - Validation

private extension ScratchWorkspace {
  static func validate(_ request: ExecutionRequest) throws {
    let expectedEntrypoint = ExecEntrypoint.fileName(for: request.language)

    guard
      request.entrypoint.name == expectedEntrypoint,
      request.entrypoint.mode == .readExecute,
      request.entrypoint.bytes.count <= maxEntrypointBytes
    else {
      throw ScratchWorkspaceError.invalidRequest("invalid execution entrypoint")
    }

    guard request.inputs.count <= maxInputFiles else {
      throw ScratchWorkspaceError.invalidRequest("too many staged inputs")
    }

    var normalizedNames = Set<String>()
    var totalBytes = 0

    for input in request.inputs {
      guard input.mode == .readOnly else {
        throw ScratchWorkspaceError.invalidRequest("staged input mode is not read-only")
      }

      guard isBareName(input.name), !isReserved(input.name) else {
        throw ScratchWorkspaceError.invalidRequest("invalid staged input name")
      }

      let normalized = input.name.precomposedStringWithCanonicalMapping.lowercased()
      guard normalizedNames.insert(normalized).inserted else {
        throw ScratchWorkspaceError.invalidRequest("duplicate staged input name")
      }

      guard input.bytes.count <= maxInputBytes else {
        throw ScratchWorkspaceError.invalidRequest("staged input exceeds per-file limit")
      }

      let addition = totalBytes.addingReportingOverflow(input.bytes.count)
      guard !addition.overflow, addition.partialValue <= maxInputTotalBytes else {
        throw ScratchWorkspaceError.invalidRequest("staged inputs exceed total limit")
      }

      totalBytes = addition.partialValue
    }
  }

  static func isBareName(_ name: String) -> Bool {
    !name.isEmpty
      && name != "."
      && name != ".."
      && !name.contains("/")
      && !name.contains("\\")
      && URL(fileURLWithPath: name).lastPathComponent == name
  }

  static func isReserved(_ name: String) -> Bool {
    name.precomposedStringWithCanonicalMapping.lowercased().hasPrefix(ExecEntrypoint.reservedPrefix)
  }
}

// MARK: - Filesystem

private extension ScratchWorkspace {
  static func ensurePrivateDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )

      guard chmod(url.path, 0o700) == 0 else {
        throw ScratchWorkspaceError.fileSystem("cannot set private directory mode")
      }
    } catch let error as ScratchWorkspaceError {
      throw error
    } catch {
      throw ScratchWorkspaceError.fileSystem("cannot create private directory")
    }
  }

  static func write(_ file: StagedFile, in directory: URL) throws {
    let destination = directory.appending(path: file.name)
    let descriptor = destination.path.withCString { path in
      open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(file.mode.rawValue))
    }

    guard descriptor >= 0 else {
      throw ScratchWorkspaceError.fileSystem("cannot create staged copy")
    }
    defer {
      _ = close(descriptor)
    }

    guard fchmod(descriptor, mode_t(file.mode.rawValue)) == 0 else {
      throw ScratchWorkspaceError.fileSystem("cannot set staged copy mode")
    }

    try file.bytes.withUnsafeBytes { bytes in
      // An empty Data may expose a nil baseAddress; nothing to write in that case.
      guard let base = bytes.baseAddress else {
        return
      }

      var offset = 0
      while offset < bytes.count {
        let written = systemWrite(descriptor, base.advanced(by: offset), bytes.count - offset)

        guard written > 0 else {
          throw ScratchWorkspaceError.fileSystem("cannot write staged copy")
        }

        offset += written
      }
    }
  }

  static func systemWrite(
    _ descriptor: Int32,
    _ bytes: UnsafeRawPointer,
    _ count: Int
  ) -> Int {
    #if canImport(Darwin)
      Darwin.write(descriptor, bytes, count)
    #elseif canImport(Glibc)
      Glibc.write(descriptor, bytes, count)
    #else
      -1
    #endif
  }
}
