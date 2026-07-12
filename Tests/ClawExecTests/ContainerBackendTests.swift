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

  func backend() -> ContainerBackend {
    ContainerBackend(
      settings: settings,
      stateRoot: root,
      commands: NoopCommandRunner(),
      sanitizeReason: { reason in
        reason
      }
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
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
