import ClawCore
import ClawProcess
import ClawTestSupport
import Foundation
import Testing

@testable import ClawExec

@Suite struct ContainerBackendExecutionTests {
  @Test(.timeLimit(.minutes(1)))
  func concurrentRunsStayNonOverlappingAndExecuteFIFO() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let firstRunGate = AsyncGate()
    let admissions = ExecutionAdmissionRecorder()
    let runner = ScriptedCommandRunner { command, history in
      switch command.arguments.first {
      case "run":
        writeCidfile(from: command.arguments)
        let runNumber = history.filter { $0.arguments.first == "run" }.count
        if runNumber == 1 {
          await firstRunGate.wait()
        }
        return commandResult(.exited(Int32(runNumber)))
      case "system":
        return jsonCommandResult(#"{"status":"running"}"#)
      case "list":
        return jsonCommandResult("[]")
      default:
        return commandResult(.exited(0))
      }
    }
    let backend = fixture.backend(commands: runner, executionAdmitted: admissions.record)
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")
    let first = Task {
      await backend.run(executionRequest(timeout: .seconds(1)))
    }
    await admissions.waitForCount(1)
    await runner.waitForCount(1)
    let second = Task {
      await backend.run(executionRequest(timeout: .seconds(2)))
    }
    await admissions.waitForCount(2)
    let third = Task {
      await backend.run(executionRequest(timeout: .seconds(3)))
    }
    await admissions.waitForCount(3)

    // then
    let blockedRunCommands = await runner.recorded().filter { $0.arguments.first == "run" }
    #expect(blockedRunCommands.count == 1)

    // when
    await firstRunGate.open()
    let results = await [first.value, second.value, third.value]

    // then
    #expect(
      results.map(\.terminationReason) == [.exited(code: 1), .exited(code: 2), .exited(code: 3)]
    )
    let runCommands = await runner.recorded().filter { $0.arguments.first == "run" }
    #expect(runCommands.map(\.timeout) == [.seconds(1), .seconds(2), .seconds(3)])
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

  @Test func everyContainerCommandKeepsTheAmbientEnvironmentDeletions() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { command, _ in
      switch command.arguments.first {
      case "run":
        writeCidfile(from: command.arguments)
        return commandResult(.exited(0))
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
    _ = await backend.run(executionRequest())

    // then
    let commands = await runner.recorded()
    #expect(!commands.isEmpty)
    #expect(
      commands.allSatisfy {
        $0.environment
          == .inherit(
            removingKeys: ["SSH_AUTH_SOCK", "CONTAINER_DEBUG", "CONTAINER_DEFAULT_PLATFORM"]
          )
      }
    )
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

  @Test(.timeLimit(.minutes(1)))
  func cancellationWhileQueuedReturnsCancelledWithoutStartingOperation() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let firstRunGate = AsyncGate()
    let admissions = ExecutionAdmissionRecorder()
    let runner = ScriptedCommandRunner { command, history in
      switch command.arguments.first {
      case "run":
        writeCidfile(from: command.arguments)
        let runNumber = history.filter { $0.arguments.first == "run" }.count
        if runNumber == 1 {
          await firstRunGate.wait()
        }
        return commandResult(.exited(Int32(runNumber)))
      case "system":
        return jsonCommandResult(#"{"status":"running"}"#)
      case "list":
        return jsonCommandResult("[]")
      default:
        return commandResult(.exited(0))
      }
    }
    let backend = fixture.backend(commands: runner, executionAdmitted: admissions.record)
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")
    let first = Task {
      await backend.run(executionRequest())
    }
    await admissions.waitForCount(1)
    await runner.waitForCount(1)
    let queued = Task {
      await backend.run(executionRequest(timeout: .seconds(2)))
    }
    await admissions.waitForCount(2)

    // when
    queued.cancel()
    await firstRunGate.open()
    _ = await first.value
    let result = await queued.value

    // then
    #expect(result.terminationReason == .cancelled)
    let runCommands = await runner.recorded().filter { $0.arguments.first == "run" }
    #expect(runCommands.count == 1)
  }
}
