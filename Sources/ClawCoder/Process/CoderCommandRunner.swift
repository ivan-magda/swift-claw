import ClawCore
import Foundation
import Subprocess
import Synchronization

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

struct CoderCommandRunner: Sendable {
  static let diagnosticByteLimit = 64 * 1024
  static let readOnlyTimeout: Duration = .seconds(10)

  func run(
    _ command: CoderCommand,
    tracking: CoderCommandTracking,
    onStandardOutput: @Sendable @escaping (Data) async throws -> Void
  ) async -> CoderCommandResult {
    let control = CoderCommandControl()
    if Task.isCancelled { control.requestCancellation() }
    let timeout: Duration
    switch tracking {
    case .preApprovalReadOnly: timeout = Self.readOnlyTimeout
    case .job: timeout = command.timeout
    }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    let operation = Task {
      await CoderCommandOperation(control: control, deadline: deadline).run(
        command,
        tracking: tracking,
        onStandardOutput: onStandardOutput
      )
    }
    return await withTaskCancellationHandler {
      await operation.value
    } onCancel: {
      control.requestCancellation()
    }
  }
}

private struct CoderCommandOperation: Sendable {
  let control: CoderCommandControl
  let deadline: ContinuousClock.Instant

  func run(
    _ command: CoderCommand,
    tracking: CoderCommandTracking,
    onStandardOutput: @Sendable @escaping (Data) async throws -> Void
  ) async -> CoderCommandResult {
    let launchID = UUID()
    do {
      let receipt = CoderProcessReceipt(
        launchID: launchID,
        phase: command.phase,
        hostBootID: try CoderProcessIdentity.bootID(),
        pid: nil,
        pgid: nil,
        birthIdentity: nil
      )
      await recordLaunchIntent(receipt, tracking: tracking)
      if await control.stopping { throw CancellationError() }
      await control.setReceipt(receipt)
      let result = try await spawn(
        command,
        tracking: tracking,
        onStandardOutput: onStandardOutput
      )
      let resolved = await finish(
        tracking,
        launchID: launchID,
        resolved: result.closureResult.cleanupResolved
      )
      let capture = await control.capture(resolved: resolved)
      let exitCode: Int32?
      let signal: Int32?
      switch result.terminationStatus {
      case .exited(let code):
        exitCode = code
        signal = nil
      case .signaled(let code):
        exitCode = nil
        signal = code
      }
      return CoderCommandResult(
        exitCode: exitCode,
        signal: signal,
        cancelled: capture.cancelled,
        timedOut: capture.timedOut,
        cleanupResolved: resolved,
        supervisionFailed: capture.supervisionFailed || !resolved,
        diagnostics: capture.diagnostics
      )
    } catch {
      if !(await control.stopping) { await control.fail("Coder process launch failed.") }
      let spawned = await control.spawned
      let resolved = await finish(tracking, launchID: launchID, resolved: !spawned)
      let capture = await control.capture(resolved: resolved)
      return CoderCommandResult(
        exitCode: nil,
        signal: nil,
        cancelled: capture.cancelled,
        timedOut: capture.timedOut,
        cleanupResolved: resolved,
        supervisionFailed: capture.supervisionFailed,
        diagnostics: capture.diagnostics
      )
    }
  }
}

// MARK: - Scoped lifetime

private extension CoderCommandOperation {
  func recordLaunchIntent(_ receipt: CoderProcessReceipt, tracking: CoderCommandTracking) async {
    await runCallbacks {
      do { try await tracking.record(.willLaunch(receipt)) } catch {
        await control.recordCallbackFailure(
          error,
          message: "Coder launch receipt could not be persisted."
        )
      }
    }
  }

  func spawn(
    _ command: CoderCommand,
    tracking: CoderCommandTracking,
    onStandardOutput: @Sendable @escaping (Data) async throws -> Void
  ) async throws -> Subprocess.ExecutionResult<CoderScopedCapture, SequenceOutput, SequenceOutput> {
    let environment = Dictionary(
      uniqueKeysWithValues: command.environment.map { key, value in
        (Environment.Key(stringLiteral: key), value)
      }
    )
    var options = PlatformOptions()
    options.createSession = true
    options.teardownSequence = [
      .gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(2))
    ]
    if control.cancellationRequested {
      await control.latchCancelled()
      throw CancellationError()
    }
    return try await Subprocess.run(
      .path(FilePath(command.executable)),
      arguments: Arguments(command.arguments),
      environment: .custom(environment),
      workingDirectory: FilePath(command.workingDirectory),
      platformOptions: options,
      input: .string(command.input),
      output: .sequence,
      error: .sequence
    ) { execution in
      await runScoped(
        execution: execution,
        command: command,
        tracking: tracking,
        onStandardOutput: onStandardOutput
      )
    }
  }

  func runScoped<Input: InputProtocol>(
    execution: Execution<Input, SequenceOutput, SequenceOutput>,
    command: CoderCommand,
    tracking: CoderCommandTracking,
    onStandardOutput: @Sendable @escaping (Data) async throws -> Void
  ) async -> CoderScopedCapture {
    let pid = Int32(execution.processIdentifier.value)
    await control.markSpawned()
    let initial = await control.receipt
    guard let initial else {
      try? execution.send(signal: .kill, toProcessGroup: false)
      return await control.capture(resolved: false)
    }
    let identity = try? CoderProcessIdentity.read(pid)
    let receipt = CoderProcessReceipt(
      launchID: initial.launchID,
      phase: initial.phase,
      hostBootID: initial.hostBootID,
      pid: pid,
      pgid: identity?.pgid,
      birthIdentity: identity?.birth
    )
    let ownedGroup = ManagedCoderProcessGroup(receipt: receipt)
    async let supervision = supervise(execution: execution, group: ownedGroup, deadline: deadline)
    await runCallbacks {
      do { try await tracking.record(.didLaunch(receipt)) } catch {
        await control.recordCallbackFailure(
          error,
          message: "Coder process receipt could not be persisted."
        )
      }
      async let output: Void = readOutput(execution.standardOutput, consumer: onStandardOutput)
      async let diagnostics: Void = readDiagnostics(execution.standardError)
      _ = await (output, diagnostics)
    }
    let resolved = await supervision
    return await control.capture(resolved: resolved)
  }

  func supervise<Input: InputProtocol>(
    execution: Execution<Input, SequenceOutput, SequenceOutput>,
    group: ManagedCoderProcessGroup,
    deadline: ContinuousClock.Instant
  ) async -> Bool {
    let resolved = await observe(
      pid: Int32(execution.processIdentifier.value),
      group: group,
      deadline: deadline
    )
    if !resolved {
      await control.fail("Coder process group cleanup is unresolved.")
      // The scope pins the direct child's PID even when group identity is unreadable.
      try? execution.send(signal: .kill, toProcessGroup: false)
    }
    return resolved
  }

  func observe(
    pid: Int32,
    group: ManagedCoderProcessGroup,
    deadline: ContinuousClock.Instant
  ) async -> Bool {
    while true {
      if await control.callbackStopNeeded(deadline: deadline) { return await group.terminate() }
      do {
        if try CoderProcessIdentity.childExited(pid) {
          if try group.liveMembers().isEmpty { return true }
          return await group.terminate()
        }
      } catch { return false }
      try? await Task.sleep(for: ManagedCoderProcessGroup.pollInterval)
    }
  }

  func readOutput(
    _ sequence: SubprocessOutputSequence,
    consumer: @Sendable (Data) async throws -> Void
  ) async {
    do {
      for try await buffer in sequence {
        let data = buffer.withUnsafeBytes { bytes in
          Data(bytes)
        }
        do { try await consumer(data) } catch {
          await control.recordCallbackFailure(
            error,
            message: "Coder standard output consumer failed."
          )
          return
        }
      }
    } catch {
      // Subprocess cancels registered IO when its leader exits, before the body returns.
      if !(error is CancellationError), !Task.isCancelled {
        await control.noteStreamError()
      }
    }
  }

  func readDiagnostics(_ sequence: SubprocessOutputSequence) async {
    do {
      for try await buffer in sequence {
        let data = buffer.withUnsafeBytes { bytes in
          Data(bytes)
        }
        await control.appendDiagnostics(data)
      }
    } catch {
      if !(error is CancellationError), !Task.isCancelled { await control.noteStreamError() }
    }
  }

  func runCallbacks(_ operation: @Sendable @escaping () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await operation()
      }
      group.addTask {
        while !Task.isCancelled {
          if await control.callbackStopNeeded(deadline: deadline) { return }
          try? await Task.sleep(for: ManagedCoderProcessGroup.pollInterval)
        }
      }
      _ = await group.next()
      group.cancelAll()
      await group.waitForAll()
    }
  }

  func finish(_ tracking: CoderCommandTracking, launchID: UUID, resolved: Bool) async -> Bool {
    do {
      try await tracking.record(
        resolved ? .stopped(launchID: launchID) : .unresolved(launchID: launchID)
      )
      return resolved
    } catch { return false }
  }
}

private actor CoderCommandControl {
  nonisolated let cancellation = Atomic(false)
  private(set) var receipt: CoderProcessReceipt?
  private(set) var spawned = false
  private(set) var failed = false
  private var cancelled = false
  private var timedOut = false
  private var diagnostics = Data()

  var stopping: Bool { cancelled || timedOut || failed }

  nonisolated var cancellationRequested: Bool { cancellation.load(ordering: .acquiring) }

  nonisolated func requestCancellation() { cancellation.store(true, ordering: .releasing) }
  func setReceipt(_ value: CoderProcessReceipt) { receipt = value }
  func markSpawned() { spawned = true }

  func latchCancelled() {
    if !timedOut { cancelled = true }
  }
  func callbackStopNeeded(deadline: ContinuousClock.Instant) -> Bool {
    guard !Task.isCancelled else {
      return false
    }
    if stopping { return true }
    if cancellationRequested { latchCancelled() }
    if !cancelled, ContinuousClock.now >= deadline { timedOut = true }
    return stopping
  }
  func recordCallbackFailure(_ error: any Error, message: String) {
    if error is CancellationError, Task.isCancelled, stopping { return }
    fail(message)
  }

  func fail(_ message: String) {
    failed = true
    appendDiagnostics(Data(message.utf8))
  }
  func noteStreamError() { fail("Coder process stream failed.") }
  func appendDiagnostics(_ bytes: Data) {
    diagnostics.append(
      bytes.prefix(max(0, CoderCommandRunner.diagnosticByteLimit - diagnostics.count))
    )
  }
  func capture(resolved: Bool) -> CoderScopedCapture {
    CoderScopedCapture(
      cancelled: cancelled,
      timedOut: timedOut,
      cleanupResolved: resolved,
      supervisionFailed: failed || !resolved,
      diagnostics: renderedDiagnostics()
    )
  }
}

// MARK: - Diagnostic rendering

private extension CoderCommandControl {
  func renderedDiagnostics() -> String {
    // Malformed stderr remains diagnostic text through replacement of invalid UTF-8.
    // swiftlint:disable:next optional_data_string_conversion
    var prefix = String(decoding: diagnostics, as: UTF8.self).utf8
      .prefix(CoderCommandRunner.diagnosticByteLimit)
    while true {
      if let text = String(bytes: prefix, encoding: .utf8) { return text }
      prefix = prefix.dropLast()
    }
  }
}
