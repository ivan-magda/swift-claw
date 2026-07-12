import ClawCore
import Foundation
import Testing

@testable import ClawExec

@Suite struct ContainerBackendTests {
  @Test func materializerCreatesPrivateRootsExactFilesAndExternalCidfile() throws {
    // given
    let fixture = try ScratchFixture()
    defer { fixture.remove() }
    let identity = try fixedIdentity()
    let request = executionRequest(
      input: StagedFile(name: "input.txt", bytes: Data("private copy".utf8), mode: .readOnly)
    )

    // when
    let workspace = try ScratchWorkspace.create(
      stateRoot: fixture.root,
      identity: identity,
      request: request
    )

    // then
    #expect(try permissions(workspace.scratchRoot) == 0o700)
    #expect(try permissions(workspace.controlRoot) == 0o700)
    #expect(try permissions(workspace.directory) == 0o700)
    #expect(try permissions(workspace.directory.appending(path: ".clawd-entrypoint.py")) == 0o500)
    #expect(try permissions(workspace.directory.appending(path: "input.txt")) == 0o400)
    #expect(
      try Data(contentsOf: workspace.directory.appending(path: "input.txt"))
        == Data("private copy".utf8)
    )
    #expect(workspace.cidFile.deletingLastPathComponent() == workspace.controlRoot)
    #expect(!workspace.cidFile.path.hasPrefix(workspace.directory.path + "/"))
  }

  @Test func materializerRejectsPathReservedAndCaseFoldedCollisionsBeforeRunDirectory() throws {
    // given
    let fixture = try ScratchFixture()
    defer { fixture.remove() }
    let badInputs = [
      StagedFile(name: "../escape", bytes: Data(), mode: .readOnly),
      StagedFile(name: ".clawd-entrypoint.payload", bytes: Data(), mode: .readOnly),
      StagedFile(name: "Readme", bytes: Data(), mode: .readOnly),
      StagedFile(name: "README", bytes: Data(), mode: .readOnly),
    ]
    let request = ExecutionRequest(
      language: .python,
      entrypoint: pythonEntrypoint(),
      inputs: badInputs,
      network: false,
      timeout: .seconds(1)
    )

    // when
    let result = Result {
      try ScratchWorkspace.create(
        stateRoot: fixture.root,
        identity: try fixedIdentity(),
        request: request
      )
    }

    // then
    #expect(throws: ScratchWorkspaceError.self) { try result.get() }
    let runDirectory = fixture.root.appending(path: "exec-scratch")
      .appending(path: try fixedIdentity().identifier)
    #expect(!FileManager.default.fileExists(atPath: runDirectory.path))
  }

  @Test func materializerRejectsWrongEntrypointNameAndModes() throws {
    // given
    let fixture = try ScratchFixture()
    defer { fixture.remove() }
    let request = ExecutionRequest(
      language: .sh,
      entrypoint: StagedFile(
        name: ".clawd-entrypoint.py",
        bytes: Data("echo no".utf8),
        mode: .readOnly
      ),
      inputs: [StagedFile(name: "input", bytes: Data(), mode: .readExecute)],
      network: false,
      timeout: .seconds(1)
    )

    // when / then
    #expect(throws: ScratchWorkspaceError.self) {
      try ScratchWorkspace.create(
        stateRoot: fixture.root,
        identity: try fixedIdentity(),
        request: request
      )
    }
  }

  @Test func materializerEnforcesEntrypointPerFileAndTotalBounds() throws {
    // given
    let fixture = try ScratchFixture()
    defer { fixture.remove() }
    let oversizedEntrypoint = StagedFile(
      name: ".clawd-entrypoint.py",
      bytes: Data(repeating: 0x61, count: ScratchWorkspace.maxEntrypointBytes + 1),
      mode: .readExecute
    )
    let oversizedInput = StagedFile(
      name: "large",
      bytes: Data(repeating: 0x62, count: ScratchWorkspace.maxInputBytes + 1),
      mode: .readOnly
    )

    // when / then
    #expect(throws: ScratchWorkspaceError.self) {
      try ScratchWorkspace.create(
        stateRoot: fixture.root,
        identity: try fixedIdentity(),
        request: ExecutionRequest(
          language: .python,
          entrypoint: oversizedEntrypoint,
          inputs: [],
          network: false,
          timeout: .seconds(1)
        )
      )
    }
    #expect(throws: ScratchWorkspaceError.self) {
      try ScratchWorkspace.create(
        stateRoot: fixture.root,
        identity: try fixedIdentity(),
        request: ExecutionRequest(
          language: .python,
          entrypoint: pythonEntrypoint(),
          inputs: [oversizedInput],
          network: false,
          timeout: .seconds(1)
        )
      )
    }
  }

  @Test func workspaceRemovalDeletesScratchAndCidfileIdempotently() throws {
    // given
    let fixture = try ScratchFixture()
    defer { fixture.remove() }
    let workspace = try ScratchWorkspace.create(
      stateRoot: fixture.root,
      identity: try fixedIdentity(),
      request: executionRequest()
    )
    FileManager.default.createFile(atPath: workspace.cidFile.path, contents: Data("owned".utf8))

    // when
    try workspace.remove()
    try workspace.remove()

    // then
    #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
    #expect(!FileManager.default.fileExists(atPath: workspace.cidFile.path))
  }

  @Test func storedTaskChainPreventsActorReentrancyFromOverlappingExecutions() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let backend = fixture.backend()
    let gate = AsyncGate()
    let recorder = ExecutionRecorder()
    let first = Task {
      await backend.runSerializedForTesting {
        await recorder.record(1)
        await gate.wait()
        return testExecutionResult(code: 1)
      }
    }
    await recorder.waitForCount(1)

    // when
    let second = Task {
      await backend.runSerializedForTesting {
        await recorder.record(2)
        return testExecutionResult(code: 2)
      }
    }
    await waitForQueuedCount(2, backend: backend)

    // then
    #expect(await recorder.values() == [1])
    await gate.open()
    #expect(await first.value.terminationReason == .exited(code: 1))
    #expect(await second.value.terminationReason == .exited(code: 2))
    #expect(await recorder.values() == [1, 2])
  }

  @Test func storedTaskChainPreservesAdmissionFIFO() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let backend = fixture.backend()
    let gate = AsyncGate()
    let recorder = ExecutionRecorder()
    let first = Task {
      await backend.runSerializedForTesting {
        await recorder.record(1)
        await gate.wait()
        return testExecutionResult(code: 1)
      }
    }
    await recorder.waitForCount(1)
    let second = Task {
      await backend.runSerializedForTesting {
        await recorder.record(2)
        return testExecutionResult(code: 2)
      }
    }
    await waitForQueuedCount(2, backend: backend)
    let third = Task {
      await backend.runSerializedForTesting {
        await recorder.record(3)
        return testExecutionResult(code: 3)
      }
    }
    await waitForQueuedCount(3, backend: backend)

    // when
    await gate.open()
    _ = await [first.value, second.value, third.value]

    // then
    #expect(await recorder.values() == [1, 2, 3])
  }

  @Test func runRequiresPreparedRuntimeInitImageWithoutStartingACommand() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { _, _ in
      commandResult(.exited(0))
    }
    let backend = fixture.backend(commands: runner)

    // when
    let result = await backend.run(executionRequest())

    // then
    #expect(result.terminationReason == .unavailable(reason: "sandbox is not prepared"))
    #expect(await runner.recorded().isEmpty)
  }

  @Test func cidBackedNonzeroExitIsGuestResultWithLossyBoundedStreams() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { command, _ in
      switch command.arguments.first {
      case "run":
        writeCidfile(from: command.arguments)
        return commandResult(
          .exited(7),
          stdout: Data([0x66, 0x6f, 0x80]),
          stderr: Data("guest error".utf8),
          stdoutTotal: 2_000_000,
          stdoutTruncated: true
        )
      case "system":
        return jsonCommandResult(#"{"status":"running"}"#)
      case "list":
        return jsonCommandResult("[]")
      default:
        return commandResult(.exited(0))
      }
    }
    let backend = fixture.backend(commands: runner)
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")

    // when
    let result = await backend.run(executionRequest())

    // then
    #expect(result.terminationReason == .exited(code: 7))
    #expect(result.stdout == "fo\u{FFFD}")
    #expect(result.stderr == "guest error")
    #expect(result.truncatedRawBytes)
    let arguments = await runner.recorded().map(\.arguments)
    #expect(arguments[0].first == "run")
    #expect(arguments.contains { $0.first == "stop" })
    #expect(arguments.contains { $0.first == "kill" })
    #expect(arguments.contains { $0.first == "rm" })
    #expect(arguments.last == ContainerInvocation.listAll())
    #expect(try scratchChildren(fixture.root).isEmpty)
  }

  @Test func nonzeroExitWithoutCidfileIsStartFailureAndHidesGuestStreams() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { command, _ in
      if command.arguments.first == "list" {
        return jsonCommandResult("[]")
      }
      return commandResult(
        .exited(command.arguments.first == "run" ? 125 : 0),
        stdout: Data("secret".utf8)
      )
    }
    let backend = fixture.backend(
      commands: runner,
      sanitizeReason: { $0.replacingOccurrences(of: "secret", with: "[REDACTED]") }
    )
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")

    // when
    let result = await backend.run(executionRequest())

    // then
    guard case .startFailed(let reason) = result.terminationReason else {
      Issue.record("expected startFailed")
      return
    }
    #expect(reason == "container did not create its identity file")
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.isEmpty)
  }

  @Test func engineFailureOrSurvivingNameOverridesAnExitedCli() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { command, history in
      switch command.arguments.first {
      case "run":
        writeCidfile(from: command.arguments)
        return commandResult(.exited(0))
      case "system":
        return jsonCommandResult(#"{"status":"running"}"#)
      case "list" where history.count < 5:
        let name = value(after: "--name", in: history[0].arguments) ?? "missing-name"
        return jsonCommandResult(
          "[{\"id\":\"\(name)\",\"configuration\":{\"id\":\"\(name)\",\"labels\":{\"clawd.exec\":\"1\"}}}]"
        )
      case "list":
        return jsonCommandResult("[]")
      default:
        return commandResult(.exited(0))
      }
    }
    let backend = fixture.backend(commands: runner)
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")

    // when
    let result = await backend.run(executionRequest())

    // then
    #expect(
      result.terminationReason
        == .startFailed(reason: "container remained after the foreground CLI exited")
    )
  }

  @Test func timeoutUsesProgramBudgetThenRunsShieldedIdentityLadder() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { command, _ in
      switch command.arguments.first {
      case "run":
        writeCidfile(from: command.arguments)
        return commandResult(.timedOut, stdout: Data("partial".utf8))
      case "list":
        return jsonCommandResult("[]")
      default:
        return commandResult(.exited(0))
      }
    }
    let backend = fixture.backend(commands: runner)
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")
    let request = ExecutionRequest(
      language: .python,
      entrypoint: pythonEntrypoint(),
      inputs: [],
      network: false,
      timeout: .seconds(3)
    )

    // when
    let result = await backend.run(request)

    // then
    #expect(result.terminationReason == .timedOutKilled)
    #expect(result.stdout.isEmpty)
    let commands = await runner.recorded()
    #expect(commands[0].timeout == .seconds(3))
    #expect(
      commands.dropFirst().allSatisfy { $0.timeout <= ContainerBackend.lifecycleCommandTimeout }
    )
    let name = try #require(value(after: "--name", in: commands[0].arguments))
    #expect(commands.map(\.arguments).contains(ContainerInvocation.stop(name)))
    #expect(commands.map(\.arguments).contains(ContainerInvocation.kill(name)))
    #expect(commands.map(\.arguments).contains(ContainerInvocation.remove(name)))
    #expect(try scratchChildren(fixture.root).isEmpty)
  }

  @Test func hostWatchdogBoundsHungForegroundRunThenRunsShieldedIdentityLadder() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { command, _ in
      if command.arguments.first == "run" {
        writeCidfile(from: command.arguments)
        // A wedged foreground CLI: never returns until the watchdog cancels the losing racer.
        while !Task.isCancelled { await Task.yield() }
        return commandResult(.cancelled)
      }
      return command.arguments.first == "list"
        ? jsonCommandResult("[]")
        : commandResult(.exited(0))
    }
    let nowSource = SteppingNowSource()
    let backend = fixture.backend(commands: runner, now: { nowSource.next() })
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")

    // when
    let result = await backend.run(executionRequest())

    // then
    #expect(result.terminationReason == .timedOutKilled)
    let commands = await runner.recorded()
    let name = try #require(value(after: "--name", in: commands[0].arguments))
    let arguments = commands.map(\.arguments)
    #expect(arguments.contains(ContainerInvocation.stop(name)))
    #expect(arguments.contains(ContainerInvocation.kill(name)))
    #expect(arguments.contains(ContainerInvocation.remove(name)))
    #expect(arguments.last == ContainerInvocation.listAll())
    #expect(try scratchChildren(fixture.root).isEmpty)
  }

  @Test func cancellationWhileRunningStillCleansIdentityAndScratch() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { command, _ in
      if command.arguments.first == "run" {
        writeCidfile(from: command.arguments)
        while !Task.isCancelled { await Task.yield() }
        return commandResult(.cancelled)
      }
      return command.arguments.first == "list"
        ? jsonCommandResult("[]")
        : commandResult(.exited(0))
    }
    let backend = fixture.backend(commands: runner)
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")
    let task = Task {
      await backend.run(executionRequest())
    }
    await runner.waitForCount(1)

    // when
    task.cancel()
    let result = await task.value

    // then
    #expect(result.terminationReason == .cancelled)
    let arguments = await runner.recorded().map(\.arguments)
    #expect(arguments.contains { $0.first == "stop" })
    #expect(arguments.contains { $0.first == "kill" })
    #expect(arguments.contains { $0.first == "rm" })
    #expect(arguments.last == ContainerInvocation.listAll())
    #expect(try scratchChildren(fixture.root).isEmpty)
  }

  @Test func finalPresenceFailureOverridesGuestOrCancellationResult() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { command, history in
      if command.arguments.first == "run" {
        writeCidfile(from: command.arguments)
        return commandResult(.timedOut)
      }
      if command.arguments.first == "list" {
        let name = value(after: "--name", in: history[0].arguments) ?? "missing-name"
        return jsonCommandResult("[{\"id\":\"\(name)\"}]")
      }
      return commandResult(.exited(0))
    }
    let backend = fixture.backend(commands: runner)
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")

    // when
    let result = await backend.run(executionRequest())

    // then
    guard case .startFailed(let reason) = result.terminationReason else {
      Issue.record("expected cleanup start failure")
      return
    }
    #expect(reason.contains("could not confirm container removal"))
  }

  @Test func cancellationWhileQueuedReturnsCancelledWithoutStartingOperation() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let backend = fixture.backend()
    let gate = AsyncGate()
    let recorder = ExecutionRecorder()
    let first = Task {
      await backend.runSerializedForTesting {
        await recorder.record(1)
        await gate.wait()
        return testExecutionResult(code: 1)
      }
    }
    await recorder.waitForCount(1)
    let queued = Task {
      await backend.runSerializedForTesting {
        await recorder.record(2)
        return testExecutionResult(code: 2)
      }
    }
    await waitForQueuedCount(2, backend: backend)

    // when
    queued.cancel()
    await gate.open()
    _ = await first.value
    let result = await queued.value

    // then
    #expect(result.terminationReason == .cancelled)
    #expect(await recorder.values() == [1])
  }

  @Test func probeRejectsUnsupportedHostBeforeAnySubprocess() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { _, _ in
      commandResult(.exited(0))
    }
    let backend = fixture.backend(commands: runner, supportedHost: { false })

    // when
    let availability = await backend.probe()

    // then
    #expect(
      availability == .unavailable(reason: "execute_code requires macOS 26 or newer on arm64")
    )
    #expect(await runner.recorded().isEmpty)
  }

  @Test func versionAvailabilityRejectsUnsupportedHostBeforeAnySubprocess() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { _, _ in
      commandResult(.exited(0))
    }
    let backend = fixture.backend(commands: runner, supportedHost: { false })

    // when
    let availability = await backend.versionAvailability()

    // then
    #expect(
      availability == .unavailable(reason: "execute_code requires macOS 26 or newer on arm64")
    )
    #expect(await runner.recorded().isEmpty)
  }

  @Test func probeRequiresRunningTypedSystemStatus() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { command, _ in
      command.arguments == ContainerInvocation.systemStatus()
        ? jsonCommandResult(#"{"status":"not running"}"#)
        : jsonCommandResult("[]")
    }
    let backend = fixture.backend(commands: runner, supportedHost: { true })

    // when
    let availability = await backend.probe()

    // then
    #expect(availability == .unavailable(reason: "container engine is not running"))
    #expect(await runner.recorded().map(\.arguments) == [ContainerInvocation.systemStatus()])
  }

  @Test func versionAvailabilitySelectsCLIComponentAndAcceptsTheFloor() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let json = """
      [
        {"version":"99.0.0","buildType":"release","commit":"server","appName":"container-apiserver"},
        {"version":"1.0.0","buildType":"release","commit":"cli","appName":"container"}
      ]
      """
    let runner = ScriptedCommandRunner { command, _ in
      command.arguments == ContainerInvocation.systemVersion()
        ? jsonCommandResult(json)
        : jsonCommandResult(#"{"status":"running"}"#)
    }
    let backend = fixture.backend(commands: runner, supportedHost: { true })

    // when
    let direct = await backend.versionAvailability()
    let probe = await backend.probe()

    // then
    #expect(direct == .available(engineVersion: "1.0.0"))
    #expect(probe == .available(engineVersion: "1.0.0"))
  }

  @Test(arguments: [
    "0.12.3",
    "1.0",
    "v1.0.0",
    "1.0.0-beta.1",
  ])
  func versionAvailabilityFailsClosedForOldOrMalformedCLI(version: String) async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let json = """
      [{"version":"\(version)","buildType":"release","commit":"cli","appName":"container"}]
      """
    let runner = ScriptedCommandRunner { _, _ in
      jsonCommandResult(json)
    }
    let backend = fixture.backend(commands: runner, supportedHost: { true })

    // when
    let availability = await backend.versionAvailability()

    // then
    guard case .unavailable = availability else {
      Issue.record("expected unavailable for \(version)")
      return
    }
  }

  @Test func truncatedOrMalformedVersionJSONFailsClosed() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { _, history in
      history.count == 1
        ? commandResult(
          .exited(0),
          stdout: Data("[]".utf8),
          stdoutTotal: 2_000_000,
          stdoutTruncated: true
        )
        : jsonCommandResult("not-json")
    }
    let backend = fixture.backend(commands: runner, supportedHost: { true })

    // when
    let truncated = await backend.versionAvailability()
    let malformed = await backend.versionAvailability()

    // then
    guard case .unavailable = truncated else {
      Issue.record("truncation must fail closed")
      return
    }
    guard case .unavailable = malformed else {
      Issue.record("malformed JSON must fail closed")
      return
    }
  }
}

private struct ScratchFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "clawd-scratch-tests-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func fixedIdentity() throws -> ExecutionIdentity {
  ExecutionIdentity(uuid: try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555")))
}

private func pythonEntrypoint() -> StagedFile {
  StagedFile(name: ".clawd-entrypoint.py", bytes: Data("print('ok')".utf8), mode: .readExecute)
}

private func executionRequest(input: StagedFile? = nil) -> ExecutionRequest {
  ExecutionRequest(
    language: .python,
    entrypoint: pythonEntrypoint(),
    inputs: input.map { staged in
      [staged]
    } ?? [],
    network: false,
    timeout: .seconds(1)
  )
}

private func permissions(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

private struct BackendFixture {
  let root: URL
  let settings: ExecSandboxSettings

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "clawd-backend-tests-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    settings = ExecSandboxSettings(
      workloadImage: try #require(
        PinnedImageReference.parse(
          "cgr.dev/swift-claw/python@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
      ),
      memoryMiB: 1024,
      cpus: 4
    )
  }

  func backend(
    commands: any ContainerCommandRunning = NoopCommandRunner(),
    sanitizeReason: @escaping @Sendable (String) -> String = { $0 },
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
    supportedHost: @escaping @Sendable () -> Bool = { true }
  ) -> ContainerBackend {
    ContainerBackend(
      settings: settings,
      stateRoot: root,
      commands: commands,
      sanitizeReason: sanitizeReason,
      now: now,
      supportedHost: supportedHost
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

// First call anchors the execution start; every later call sits far past the outer
// deadline so the host watchdog fires deterministically without wall-clock waiting.
private final class SteppingNowSource: @unchecked Sendable {
  private let lock = NSLock()
  private let base = ContinuousClock.now
  private var calls = 0

  func next() -> ContinuousClock.Instant {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    return calls == 1 ? base : base.advanced(by: .seconds(3600))
  }
}

private struct NoopCommandRunner: ContainerCommandRunning {
  func run(_ command: ContainerCommand) async -> ContainerCommandResult {
    ContainerCommandResult(
      termination: .exited(0),
      stdout: CapturedCommandStream(bytes: Data(), totalBytes: 0, truncated: false),
      stderr: CapturedCommandStream(bytes: Data(), totalBytes: 0, truncated: false),
      processIdentifier: 1,
      wallClock: .zero
    )
  }
}

private actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for continuation in pending {
      continuation.resume()
    }
  }
}

private actor ExecutionRecorder {
  private var recorded: [Int] = []
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func record(_ value: Int) {
    recorded.append(value)
    let ready = waiters.filter { waiter in
      recorded.count >= waiter.0
    }
    waiters.removeAll { waiter in
      recorded.count >= waiter.0
    }
    for waiter in ready {
      waiter.1.resume()
    }
  }

  func waitForCount(_ count: Int) async {
    if recorded.count >= count { return }
    await withCheckedContinuation { continuation in
      waiters.append((count, continuation))
    }
  }

  func values() -> [Int] { recorded }
}

private func waitForQueuedCount(_ count: Int, backend: ContainerBackend) async {
  while await backend.queuedExecutionCountForTesting < count {
    await Task.yield()
  }
}

private func testExecutionResult(code: Int32) -> ExecutionResult {
  ExecutionResult(
    terminationReason: .exited(code: code),
    stdout: "",
    stderr: "",
    truncatedRawBytes: false,
    wallClock: .zero
  )
}
