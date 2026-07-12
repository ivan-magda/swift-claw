import Foundation

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
