import Foundation
import Subprocess
import System

public struct ContainerCommand: Sendable, Equatable {
  public let arguments: [String]
  public let timeout: Duration
  public let captureLimit: Int
  public let teardownGracePeriod: Duration

  public init(
    arguments: [String],
    timeout: Duration,
    captureLimit: Int,
    teardownGracePeriod: Duration
  ) {
    precondition(captureLimit >= 0)
    self.arguments = arguments
    self.timeout = timeout
    self.captureLimit = captureLimit
    self.teardownGracePeriod = teardownGracePeriod
  }
}

public enum ContainerCommandTermination: Sendable, Equatable {
  case exited(Int32)
  case signaled(Int32)
  case timedOut
  case cancelled
  case startFailed(String)
}

public struct CapturedCommandStream: Sendable, Equatable {
  public let bytes: Data
  public let totalBytes: Int
  public let truncated: Bool

  public init(bytes: Data, totalBytes: Int, truncated: Bool) {
    precondition(totalBytes >= bytes.count)
    self.bytes = bytes
    self.totalBytes = totalBytes
    self.truncated = truncated
  }
}

public struct ContainerCommandResult: Sendable, Equatable {
  public let termination: ContainerCommandTermination

  public let stdout: CapturedCommandStream
  public let stderr: CapturedCommandStream

  public let processIdentifier: Int32?
  public let wallClock: Duration

  public init(
    termination: ContainerCommandTermination,
    stdout: CapturedCommandStream,
    stderr: CapturedCommandStream,
    processIdentifier: Int32?,
    wallClock: Duration
  ) {
    self.termination = termination

    self.stdout = stdout
    self.stderr = stderr

    self.processIdentifier = processIdentifier
    self.wallClock = wallClock
  }
}

public protocol ContainerCommandRunning: Sendable {
  func run(_ command: ContainerCommand) async -> ContainerCommandResult
}

public struct SwiftSubprocessContainerCommandRunner: ContainerCommandRunning {
  private static let removedEnvironmentKeys = [
    "SSH_AUTH_SOCK",
    "CONTAINER_DEBUG",
    "CONTAINER_DEFAULT_PLATFORM",
  ]

  private let executablePath: String
  private let environmentForTesting: [String: String]
  private let onSpawnForTesting: @Sendable (Int32) -> Void

  public init(executablePath: String = "/usr/local/bin/container") {
    self.executablePath = executablePath
    self.environmentForTesting = [:]
    self.onSpawnForTesting = { _ in }
  }

  init(
    executablePath: String,
    environmentForTesting: [String: String] = [:],
    onSpawnForTesting: @escaping @Sendable (Int32) -> Void = { _ in }
  ) {
    self.executablePath = executablePath
    self.environmentForTesting = environmentForTesting
    self.onSpawnForTesting = onSpawnForTesting
  }

  public func run(_ command: ContainerCommand) async -> ContainerCommandResult {
    let clock = ContinuousClock()
    let started = clock.now

    let teardownSequence = Self.teardownSequence(gracePeriod: command.teardownGracePeriod)

    do {
      let result = try await Subprocess.run(
        .path(FilePath(executablePath)),
        arguments: Arguments(command.arguments),
        environment: environment(),
        workingDirectory: nil,
        platformOptions: Self.platformOptions(teardownSequence: teardownSequence),
        input: .none,
        output: .sequence,
        error: .sequence
      ) { execution in
        let processIdentifier = Int32(execution.processIdentifier.value)
        onSpawnForTesting(processIdentifier)
        // The task's value carries the verdict: a cancelled sleep means the process finished
        // first, a slept-through deadline tears the process group down and reports a timeout.
        let timeoutTask = Task<Bool, Never> {
          do {
            try await clock.sleep(for: command.timeout)
          } catch {
            return false
          }

          await execution.teardown(using: teardownSequence)

          return true
        }

        async let stdout = Self.capture(execution.standardOutput, limit: command.captureLimit)
        async let stderr = Self.capture(execution.standardError, limit: command.captureLimit)

        let streams = try await (stdout, stderr)
        timeoutTask.cancel()

        return CommandClosureResult(
          stdout: streams.0,
          stderr: streams.1,
          timedOut: await timeoutTask.value
        )
      }

      return ContainerCommandResult(
        termination: Self.classifyTermination(
          timedOut: result.closureOutput.timedOut,
          status: result.terminationStatus
        ),
        stdout: result.closureOutput.stdout,
        stderr: result.closureOutput.stderr,
        processIdentifier: Int32(result.processIdentifier.value),
        wallClock: started.duration(to: clock.now)
      )
    } catch {
      let termination: ContainerCommandTermination =
        Task.isCancelled || error is CancellationError
        ? .cancelled
        : .startFailed(String(describing: error))

      return ContainerCommandResult(
        termination: termination,
        stdout: Self.emptyStream,
        stderr: Self.emptyStream,
        processIdentifier: nil,
        wallClock: started.duration(to: clock.now)
      )
    }
  }
}

// MARK: - Launch & Termination

private extension SwiftSubprocessContainerCommandRunner {
  static func teardownSequence(gracePeriod: Duration) -> [TeardownStep] {
    [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: gracePeriod)]
  }

  static func platformOptions(teardownSequence: [TeardownStep]) -> PlatformOptions {
    var options = PlatformOptions()
    options.createSession = true
    options.teardownSequence = teardownSequence
    return options
  }

  static func classifyTermination(
    timedOut: Bool,
    status: TerminationStatus
  ) -> ContainerCommandTermination {
    if timedOut {
      return .timedOut
    }

    if Task.isCancelled {
      return .cancelled
    }

    switch status {
    case .exited(let code):
      return .exited(Int32(code))
    case .signaled(let signal):
      return .signaled(Int32(signal))
    }
  }
}

// MARK: - Environment

private extension SwiftSubprocessContainerCommandRunner {
  func environment() -> Environment {
    var updates: [Environment.Key: String?] = [:]

    for (key, value) in environmentForTesting {
      updates[Environment.Key(stringLiteral: key)] = value
    }

    for key in Self.removedEnvironmentKeys {
      updates[Environment.Key(stringLiteral: key)] = String?.none
    }

    return .inherit.updating(updates)
  }
}

// MARK: - Raw Capture

private extension SwiftSubprocessContainerCommandRunner {
  static let emptyStream = CapturedCommandStream(bytes: Data(), totalBytes: 0, truncated: false)

  static func capture(
    _ sequence: SubprocessOutputSequence,
    limit: Int
  ) async throws -> CapturedCommandStream {
    var prefix = Data()
    prefix.reserveCapacity(min(limit, 64 * 1024))

    var totalBytes = 0
    var overflowedCounter = false

    for try await buffer in sequence {
      let addition = totalBytes.addingReportingOverflow(buffer.count)

      totalBytes = addition.overflow ? Int.max : addition.partialValue
      overflowedCounter = overflowedCounter || addition.overflow

      let remaining = max(0, limit - prefix.count)
      guard remaining > 0 else {
        continue
      }

      buffer.withUnsafeBytes { bytes in
        prefix.append(contentsOf: bytes.prefix(remaining))
      }
    }

    return CapturedCommandStream(
      bytes: prefix,
      totalBytes: totalBytes,
      truncated: overflowedCounter || totalBytes > prefix.count
    )
  }
}

private struct CommandClosureResult: Sendable {
  let stdout: CapturedCommandStream
  let stderr: CapturedCommandStream
  let timedOut: Bool
}
