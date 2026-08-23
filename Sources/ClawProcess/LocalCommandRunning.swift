import ClawCore
import Foundation
import Subprocess
import Synchronization

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

/// What the child process inherits from this process: everything, minus the named keys and
/// minus every key carrying one of the named prefixes.
public struct LocalCommandEnvironment: Sendable, Equatable {
  public let removedKeys: Set<String>
  public let removedPrefixes: Set<String>

  public static func inherit(
    removingKeys removedKeys: Set<String> = [],
    removingPrefixes removedPrefixes: Set<String> = []
  ) -> LocalCommandEnvironment {
    LocalCommandEnvironment(removedKeys: removedKeys, removedPrefixes: removedPrefixes)
  }

  private init(removedKeys: Set<String>, removedPrefixes: Set<String>) {
    self.removedKeys = removedKeys
    self.removedPrefixes = removedPrefixes
  }

  /// Whether this policy drops `key` from the child's environment.
  public func removes(_ key: String) -> Bool {
    removedKeys.contains(key) || removedPrefixes.contains { key.hasPrefix($0) }
  }
}

/// Launcher-side bounds every caller shares, so a capture limit or a teardown grace cannot drift
/// between the sandbox and a host tool.
public enum LocalCommandLimits {
  /// Bytes kept per stream before the launcher stops appending; the counter keeps running so the
  /// caller can still tell the output was cut.
  public static let maxRawStreamBytes = 1024 * 1024
  public static let maxRawStreamMiB = maxRawStreamBytes / (1024 * 1024)
  /// How long a terminating process group has to leave on its own before the launcher stops waiting.
  public static let teardownGracePeriod: Duration = .seconds(2)
}

public struct LocalCommand: Sendable, Equatable {
  public let arguments: [String]
  public let timeout: Duration
  public let captureLimit: Int
  public let teardownGracePeriod: Duration
  /// Absolute path the child starts in; `nil` keeps this process's own working directory.
  public let workingDirectory: String?
  public let environment: LocalCommandEnvironment

  public init(
    arguments: [String],
    timeout: Duration,
    captureLimit: Int,
    teardownGracePeriod: Duration,
    workingDirectory: String? = nil,
    environment: LocalCommandEnvironment
  ) {
    precondition(captureLimit >= 0)
    self.arguments = arguments
    self.timeout = timeout
    self.captureLimit = captureLimit
    self.teardownGracePeriod = teardownGracePeriod
    self.workingDirectory = workingDirectory
    self.environment = environment
  }
}

public enum LocalCommandTermination: Sendable, Equatable {
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

public struct LocalCommandResult: Sendable, Equatable {
  public let termination: LocalCommandTermination

  public let stdout: CapturedCommandStream
  public let stderr: CapturedCommandStream

  public let processIdentifier: Int32?

  public init(
    termination: LocalCommandTermination,
    stdout: CapturedCommandStream,
    stderr: CapturedCommandStream,
    processIdentifier: Int32?
  ) {
    self.termination = termination

    self.stdout = stdout
    self.stderr = stderr

    self.processIdentifier = processIdentifier
  }
}

public protocol LocalCommandRunning: Sendable {
  func run(_ command: LocalCommand) async -> LocalCommandResult
}

public struct SwiftSubprocessLocalCommandRunner: LocalCommandRunning {
  private let executablePath: String
  private let environmentForTesting: [String: String]
  private let onSpawnForTesting: @Sendable (Int32) -> Void

  public init(executablePath: String) {
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

  public func run(_ command: LocalCommand) async -> LocalCommandResult {
    let clock = ContinuousClock()
    let spawnedProcessIdentifier = SpawnedProcessIdentifierBox()

    let outcome = await DeadlineRace.race(
      allowance: command.timeout,
      sleep: { try await clock.sleep(for: $0) },
      operation: {
        await self.spawnAndCapture(
          command,
          spawnedProcessIdentifier: spawnedProcessIdentifier
        )
      }
    )

    switch outcome {
    case .operationReturned(let result):
      return result
    case .deadlineExpired:
      return LocalCommandResult(
        termination: .timedOut,
        stdout: Self.emptyStream,
        stderr: Self.emptyStream,
        processIdentifier: spawnedProcessIdentifier.value
      )
    case .callerCancelled:
      return LocalCommandResult(
        termination: .cancelled,
        stdout: Self.emptyStream,
        stderr: Self.emptyStream,
        processIdentifier: spawnedProcessIdentifier.value
      )
    }
  }

  private func spawnAndCapture(
    _ command: LocalCommand,
    spawnedProcessIdentifier: SpawnedProcessIdentifierBox
  ) async -> LocalCommandResult {
    let teardownSequence = Self.teardownSequence(gracePeriod: command.teardownGracePeriod)

    do {
      let result = try await Subprocess.run(
        .path(FilePath(executablePath)),
        arguments: Arguments(command.arguments),
        environment: environment(for: command),
        workingDirectory: command.workingDirectory.map { FilePath($0) },
        platformOptions: Self.platformOptions(teardownSequence: teardownSequence),
        input: .none,
        output: .sequence,
        error: .sequence
      ) { execution in
        let processIdentifier = Int32(execution.processIdentifier.value)
        spawnedProcessIdentifier.value = processIdentifier
        onSpawnForTesting(processIdentifier)

        async let stdout = Self.capture(execution.standardOutput, limit: command.captureLimit)
        async let stderr = Self.capture(execution.standardError, limit: command.captureLimit)
        let streams = try await (stdout, stderr)

        return CommandClosureResult(stdout: streams.0, stderr: streams.1)
      }

      return LocalCommandResult(
        termination: Self.classifyTermination(status: result.terminationStatus),
        stdout: result.closureResult.stdout,
        stderr: result.closureResult.stderr,
        processIdentifier: Int32(result.processIdentifier.value)
      )
    } catch {
      let termination: LocalCommandTermination =
        Task.isCancelled || error is CancellationError
        ? .cancelled
        : .startFailed(String(describing: error))

      return LocalCommandResult(
        termination: termination,
        stdout: Self.emptyStream,
        stderr: Self.emptyStream,
        processIdentifier: spawnedProcessIdentifier.value
      )
    }
  }
}

// MARK: - Launch & Termination

private extension SwiftSubprocessLocalCommandRunner {
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
    status: TerminationStatus
  ) -> LocalCommandTermination {
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

private extension SwiftSubprocessLocalCommandRunner {
  func environment(for command: LocalCommand) -> Environment {
    var updates: [Environment.Key: String?] = [:]

    for (key, value) in environmentForTesting {
      updates[Environment.Key(stringLiteral: key)] = value
    }

    // A prefix names no key on its own, so the deletions have to be resolved against the set of
    // keys the child would otherwise inherit.
    let inheritedKeys = Set(ProcessInfo.processInfo.environment.keys)
      .union(environmentForTesting.keys)
      .union(command.environment.removedKeys)

    for key in inheritedKeys where command.environment.removes(key) {
      updates[Environment.Key(stringLiteral: key)] = String?.none
    }

    return .inherit.updating(updates)
  }
}

// MARK: - Raw Capture

private extension SwiftSubprocessLocalCommandRunner {
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
}

private final class SpawnedProcessIdentifierBox: Sendable {
  private let storage = Mutex<Int32?>(nil)

  var value: Int32? {
    get {
      storage.withLock { $0 }
    }
    set {
      storage.withLock {
        $0 = newValue
      }
    }
  }
}
