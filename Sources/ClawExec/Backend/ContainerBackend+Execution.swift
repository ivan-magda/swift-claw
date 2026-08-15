import ClawCore
import Foundation

// MARK: - Serialized Execution

extension ContainerBackend {
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
    executionAdmitted()

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
      truncatedRawBytes: false
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

extension ContainerBackend {
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
        "failed to materialize execution scratch: \(error)"
      )
    }

    let command = foregroundCommand(
      request: request,
      identity: identity,
      workspace: workspace,
      initImage: initImage
    )

    var result =
      switch await boundedForegroundRun(command, deadline: deadline) {
      case .operationReturned(let commandResult):
        await classify(
          commandResult,
          identity: identity,
          cidFile: workspace.cidFile,
          deadline: deadline
        )
      case .deadlineExpired:
        self.result(.timedOutKilled)
      case .callerCancelled:
        self.result(.cancelled)
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
        "could not confirm container removal for \(identity.name)"
      )
    }

    return result
  }

  private func foregroundCommand(
    request: ExecutionRequest,
    identity: ExecutionIdentity,
    workspace: ScratchWorkspace,
    initImage: String
  ) -> ContainerCommand {
    ContainerCommand(
      arguments: ContainerInvocation.run(
        context: ContainerLaunchContext(
          identity: identity,
          scratchPath: workspace.directory.path,
          settings: settings,
          initImage: initImage
        ),
        cidFilePath: workspace.cidFile.path,
        language: request.language,
        network: request.network
      ),
      timeout: request.timeout,
      captureLimit: Self.maxRawStreamBytes,
      teardownGracePeriod: Self.commandTeardownGrace
    )
  }

  // The runner enforces the guest timeout itself; this host-side watchdog is an independent
  // bound so a wedged `container run` that never returns cannot hang the execution lane. A wedged
  // runner is cancelled and abandoned after the deadline; the shielded teardown ladder plus the
  // prepared-image disarm own containment.
  func boundedForegroundRun(
    _ command: ContainerCommand,
    deadline: ContinuousClock.Instant
  ) async -> DeadlineRaceOutcome<ContainerCommandResult> {
    let commands = commands
    let remaining = now().duration(to: deadline)

    return await DeadlineRace.race(
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
    deadline: ContinuousClock.Instant
  ) async -> ExecutionResult {
    switch commandResult.termination {
    case .timedOut:
      return result(.timedOutKilled)
    case .cancelled:
      return result(.cancelled)
    case .startFailed(let reason):
      return infrastructureResult(reason)
    case .signaled(let signal):
      return infrastructureResult(
        "container CLI was terminated by host signal \(signal)"
      )
    case .exited(let code):
      guard cidMatches(identity, at: cidFile) else {
        return infrastructureResult(
          "container did not create its identity file"
        )
      }

      guard await engineRunning(deadline: deadline) else {
        return infrastructureResult(
          "container engine became unavailable after execution"
        )
      }

      guard let present = await containerPresent(identity.name, deadline: deadline) else {
        return infrastructureResult(
          "could not inspect container state after execution"
        )
      }

      guard !present else {
        return infrastructureResult(
          "container remained after the foreground CLI exited"
        )
      }

      // swiftlint:disable optional_data_string_conversion
      let stdout = String(decoding: commandResult.stdout.bytes, as: UTF8.self)
      let stderr = String(decoding: commandResult.stderr.bytes, as: UTF8.self)
      // swiftlint:enable optional_data_string_conversion
      return ExecutionResult(
        terminationReason: .exited(code: code),
        stdout: stdout,
        stderr: stderr,
        truncatedRawBytes: commandResult.stdout.truncated || commandResult.stderr.truncated
      )
    }
  }
}
