import ClawProcess
import Foundation

/// Records every command it receives and answers each one through the scripted handler, which
/// also sees the history recorded so far (including the current command).
public actor ScriptedCommandRunner: LocalCommandRunning {
  public typealias Handler =
    @Sendable (LocalCommand, [LocalCommand]) async -> LocalCommandResult

  private let handler: Handler
  private var commands: [LocalCommand] = []
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  public init(handler: @escaping Handler) {
    self.handler = handler
  }

  /// Answers every command with the same result, for a test that only reads what was launched.
  public init(result: LocalCommandResult) {
    self.init { _, _ in
      result
    }
  }

  public func run(_ command: LocalCommand) async -> LocalCommandResult {
    commands.append(command)
    let history = commands
    let ready = waiters.filter { history.count >= $0.0 }
    waiters.removeAll { history.count >= $0.0 }
    for waiter in ready {
      waiter.1.resume()
    }
    return await handler(command, history)
  }

  public func recorded() -> [LocalCommand] { commands }

  public func waitForCount(_ count: Int) async {
    if commands.count >= count { return }
    await withCheckedContinuation { continuation in
      waiters.append((count, continuation))
    }
  }
}

public struct NoopCommandRunner: LocalCommandRunning {
  public init() {}

  public func run(_ command: LocalCommand) async -> LocalCommandResult {
    LocalCommandResult(
      termination: .exited(0),
      stdout: CapturedCommandStream(bytes: Data(), totalBytes: 0, truncated: false),
      stderr: CapturedCommandStream(bytes: Data(), totalBytes: 0, truncated: false),
      processIdentifier: 1
    )
  }
}

public func commandResult(
  _ termination: LocalCommandTermination,
  stdout: Data = Data(),
  stderr: Data = Data(),
  stdoutTotal: Int? = nil,
  stderrTotal: Int? = nil,
  stdoutTruncated: Bool = false,
  stderrTruncated: Bool = false,
  processIdentifier: Int32? = 42
) -> LocalCommandResult {
  LocalCommandResult(
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
    processIdentifier: processIdentifier
  )
}

public func commandResult(
  _ termination: LocalCommandTermination,
  stdout: String,
  stderr: String = "",
  processIdentifier: Int32? = 42
) -> LocalCommandResult {
  commandResult(
    termination,
    stdout: Data(stdout.utf8),
    stderr: Data(stderr.utf8),
    processIdentifier: processIdentifier
  )
}
