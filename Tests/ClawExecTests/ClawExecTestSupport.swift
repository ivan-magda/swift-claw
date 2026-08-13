import ClawCore
import Foundation
import Synchronization
import Testing

@testable import ClawExec

/// Records every command it receives and answers each one through the scripted handler,
/// which also sees the history recorded so far (including the current command).
actor ScriptedCommandRunner: ContainerCommandRunning {
  typealias Handler =
    @Sendable (ContainerCommand, [ContainerCommand]) async -> ContainerCommandResult

  private let handler: Handler
  private var commands: [ContainerCommand] = []
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func run(_ command: ContainerCommand) async -> ContainerCommandResult {
    commands.append(command)
    let history = commands
    let ready = waiters.filter { history.count >= $0.0 }
    waiters.removeAll { history.count >= $0.0 }
    for waiter in ready {
      waiter.1.resume()
    }
    return await handler(command, history)
  }

  func recorded() -> [ContainerCommand] { commands }

  func waitForCount(_ count: Int) async {
    if commands.count >= count { return }
    await withCheckedContinuation { continuation in
      waiters.append((count, continuation))
    }
  }
}

/// Parks callers until released; `wait()` deliberately never observes cancellation so tests
/// can wedge a scripted runner, and `open()` is synchronous so a test's `defer` can always
/// release every parked continuation — none may outlive the test.
final class WedgeGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      guard !isOpen else {
        lock.unlock()
        continuation.resume()
        return
      }
      waiters.append(continuation)
      lock.unlock()
    }
  }

  func open() {
    lock.lock()
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in pending {
      waiter.resume()
    }
  }
}

func commandResult(
  _ termination: ContainerCommandTermination,
  stdout: Data = Data(),
  stderr: Data = Data(),
  stdoutTotal: Int? = nil,
  stderrTotal: Int? = nil,
  stdoutTruncated: Bool = false,
  stderrTruncated: Bool = false
) -> ContainerCommandResult {
  ContainerCommandResult(
    termination: termination,
    stdout: CapturedCommandStream(
      bytes: stdout,
      totalBytes: stdoutTotal ?? stdout.count,
      truncated: stdoutTruncated
    ),
    stderr: CapturedCommandStream(
      bytes: stderr,
      totalBytes: stderrTotal ?? stderr.count,
      truncated: stderrTruncated
    ),
    processIdentifier: 42,
    wallClock: .milliseconds(1)
  )
}

func jsonCommandResult(_ json: String) -> ContainerCommandResult {
  commandResult(.exited(0), stdout: Data(json.utf8))
}

func value(after flag: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
    return nil
  }
  return arguments[index + 1]
}

// A foreground run invocation always carries both flags; failing loudly here beats a silent
// no-op that would only surface later as an unrelated classification failure.
func writeCidfile(from arguments: [String]) {
  guard
    let path = value(after: "--cidfile", in: arguments),
    let name = value(after: "--name", in: arguments),
    (try? Data(name.utf8).write(
      to: URL(fileURLWithPath: path),
      options: .withoutOverwriting
    )) != nil
  else {
    preconditionFailure("run invocation did not carry cidfile identity")
  }
}

func scratchChildren(_ stateRoot: URL) throws -> [URL] {
  let root = stateRoot.appending(path: "exec-scratch")
  guard FileManager.default.fileExists(atPath: root.path) else { return [] }
  return try FileManager.default.contentsOfDirectory(
    at: root,
    includingPropertiesForKeys: nil
  )
}

struct ScratchFixture {
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

func fixedIdentity() throws -> ExecutionIdentity {
  ExecutionIdentity(uuid: try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555")))
}

func pythonEntrypoint() -> StagedFile {
  StagedFile(name: ".clawd-entrypoint.py", bytes: Data("print('ok')".utf8), mode: .readExecute)
}

func executionRequest(
  input: StagedFile? = nil,
  timeout: Duration = .seconds(1)
) -> ExecutionRequest {
  ExecutionRequest(
    language: .python,
    entrypoint: pythonEntrypoint(),
    inputs: input.map { staged in
      [staged]
    } ?? [],
    network: false,
    timeout: timeout
  )
}

func permissions(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

struct BackendFixture {
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
    supportedHost: @escaping @Sendable () -> Bool = { true },
    executionAdmitted: @escaping @Sendable () -> Void = {},
    watchdogSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) -> ContainerBackend {
    ContainerBackend(
      settings: settings,
      stateRoot: root,
      commands: commands,
      sanitizeReason: sanitizeReason,
      now: now,
      supportedHost: supportedHost,
      executionAdmitted: executionAdmitted,
      watchdogSleep: watchdogSleep
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

// First call anchors the execution start; every later call sits far past the outer
// deadline so the host watchdog fires deterministically without wall-clock waiting.
final class SteppingNowSource: @unchecked Sendable {
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

struct NoopCommandRunner: ContainerCommandRunning {
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

actor AsyncGate {
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

final class ExecutionAdmissionRecorder: Sendable {
  private struct State {
    var count = 0
    var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
  }

  private let state = Mutex(State())

  func record() {
    let ready = state.withLock { current in
      current.count += 1
      let ready = current.waiters.filter { current.count >= $0.0 }
      current.waiters.removeAll { current.count >= $0.0 }
      return ready
    }
    for waiter in ready {
      waiter.1.resume()
    }
  }

  func waitForCount(_ count: Int) async {
    await withCheckedContinuation { continuation in
      let shouldResume = state.withLock { current in
        guard current.count < count else {
          return true
        }
        current.waiters.append((count, continuation))
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }
}
