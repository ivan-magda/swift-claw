import ClawCore
import Foundation
import Subprocess
import Synchronization

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

package struct SwiftSubprocessRunner: SubprocessRunning {
  private let executablePath: String
  private let environmentForTesting: [String: String]
  private let onSpawnForTesting: @Sendable (Int32) async -> Void

  package init(
    executablePath: String,
    environmentForTesting: [String: String] = [:],
    onSpawnForTesting: @escaping @Sendable (Int32) async -> Void = { _ in }
  ) {
    self.executablePath = executablePath
    self.environmentForTesting = environmentForTesting
    self.onSpawnForTesting = onSpawnForTesting
  }

  package func run(_ command: SubprocessCommand) async -> SubprocessResult {
    let clock = ContinuousClock()
    let spawnedProcessIdentifier = SpawnedProcessIdentifierBox()
    let (spawned, spawnedContinuation) = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )

    let outcome = await DeadlineRace.race(
      allowance: command.timeout,
      sleep: { allowance in
        var iterator = spawned.makeAsyncIterator()
        guard await iterator.next() != nil else {
          throw CancellationError()
        }

        try Task.checkCancellation()
        try await clock.sleep(for: allowance)
      },
      operation: {
        defer { spawnedContinuation.finish() }
        return await self.spawnAndCapture(
          command,
          spawnedProcessIdentifier: spawnedProcessIdentifier,
          didSpawn: { spawnedContinuation.yield() }
        )
      }
    )

    switch outcome {
    case .operationReturned(let result):
      return result
    case .deadlineExpired:
      return SubprocessResult(
        termination: .timedOut,
        stdout: Self.emptyStream,
        stderr: Self.emptyStream,
        processIdentifier: spawnedProcessIdentifier.value
      )
    case .callerCancelled:
      return SubprocessResult(
        termination: .cancelled,
        stdout: Self.emptyStream,
        stderr: Self.emptyStream,
        processIdentifier: spawnedProcessIdentifier.value
      )
    }
  }

  private func spawnAndCapture(
    _ command: SubprocessCommand,
    spawnedProcessIdentifier: SpawnedProcessIdentifierBox,
    didSpawn: @escaping @Sendable () -> Void
  ) async -> SubprocessResult {
    let teardownSequence = Self.teardownSequence(
      gracePeriod: command.teardownGracePeriod
    )

    do {
      let result = try await Subprocess.run(
        .path(FilePath(executablePath)),
        arguments: Arguments(command.arguments),
        environment: environment(removing: command.environmentKeysToRemove),
        workingDirectory: nil,
        platformOptions: Self.platformOptions(teardownSequence: teardownSequence),
        input: .data(command.standardInput),
        output: .sequence,
        error: .sequence
      ) { execution in
        let processIdentifier = Int32(execution.processIdentifier.value)
        spawnedProcessIdentifier.value = processIdentifier
        await onSpawnForTesting(processIdentifier)
        didSpawn()

        async let stdout = Self.capture(execution.standardOutput, limit: command.captureLimit)
        async let stderr = Self.capture(execution.standardError, limit: command.captureLimit)
        let streams = try await (stdout, stderr)

        return CommandClosureResult(stdout: streams.0, stderr: streams.1)
      }

      return SubprocessResult(
        termination: Self.classifyTermination(status: result.terminationStatus),
        stdout: result.closureResult.stdout,
        stderr: result.closureResult.stderr,
        processIdentifier: Int32(result.processIdentifier.value)
      )
    } catch {
      let termination: SubprocessTermination =
        Task.isCancelled || error is CancellationError
        ? .cancelled
        : .startFailed(String(describing: error))

      return SubprocessResult(
        termination: termination,
        stdout: Self.emptyStream,
        stderr: Self.emptyStream,
        processIdentifier: spawnedProcessIdentifier.value
      )
    }
  }
}

// MARK: - Launch & Termination

private extension SwiftSubprocessRunner {
  static func teardownSequence(gracePeriod: Duration) -> [TeardownStep] {
    [
      .gracefulShutDown(
        toProcessGroup: true,
        allowedDurationToNextStep: gracePeriod
      )
    ]
  }

  static func platformOptions(teardownSequence: [TeardownStep]) -> PlatformOptions {
    var options = PlatformOptions()
    options.createSession = true
    options.teardownSequence = teardownSequence
    return options
  }

  static func classifyTermination(
    status: TerminationStatus
  ) -> SubprocessTermination {
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

private extension SwiftSubprocessRunner {
  func environment(removing keys: [String]) -> Environment {
    var updates: [Environment.Key: String?] = [:]

    for (key, value) in environmentForTesting {
      updates[Environment.Key(stringLiteral: key)] = value
    }

    for key in keys {
      updates[Environment.Key(stringLiteral: key)] = String?.none
    }

    return .inherit.updating(updates)
  }
}

// MARK: - Raw Capture

private extension SwiftSubprocessRunner {
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
