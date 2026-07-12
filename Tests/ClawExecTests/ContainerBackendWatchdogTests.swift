import ClawCore
import Foundation
import Testing

@testable import ClawExec

@Suite struct ContainerBackendWatchdogTests {
  @Test func hostWatchdogBoundsHungForegroundRunThenRunsShieldedIdentityLadder() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { command, _ in
      if command.arguments.first == "run" {
        writeCidfile(from: command.arguments)
        // A wedged foreground CLI: never returns until the watchdog cancels the losing racer.
        while !Task.isCancelled { await Task.yield() }
        return commandResult(.cancelled)
      }
      return command.arguments.first == "list"
        ? jsonCommandResult("[]")
        : commandResult(.exited(0))
    }
    let nowSource = SteppingNowSource()
    let backend = fixture.backend(commands: runner, now: { nowSource.next() })
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")

    // when
    let result = await backend.run(executionRequest())

    // then
    #expect(result.terminationReason == .timedOutKilled)
    let commands = await runner.recorded()
    let name = try #require(value(after: "--name", in: commands[0].arguments))
    let arguments = commands.map(\.arguments)
    #expect(arguments.contains(ContainerInvocation.stop(name)))
    #expect(arguments.contains(ContainerInvocation.kill(name)))
    #expect(arguments.contains(ContainerInvocation.remove(name)))
    #expect(arguments.last == ContainerInvocation.listAll())
    #expect(try scratchChildren(fixture.root).isEmpty)
  }

  @Test func hostWatchdogCompletesWhenRunnerIgnoresCancellationEntirely() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let wedge = WedgeGate()
    defer { wedge.open() }
    let runner = ScriptedCommandRunner { command, _ in
      if command.arguments.first == "run" {
        writeCidfile(from: command.arguments)
        // A truly wedged foreground CLI: never returns and never observes cancellation
        // until the test releases it after the assertions.
        await wedge.wait()
        return commandResult(.cancelled)
      }
      return command.arguments.first == "list"
        ? jsonCommandResult("[]")
        : commandResult(.exited(0))
    }
    let nowSource = SteppingNowSource()
    let backend = fixture.backend(commands: runner, now: { nowSource.next() })
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")

    // when
    let result = await backend.run(executionRequest())

    // then
    #expect(result.terminationReason == .timedOutKilled)
    let commands = await runner.recorded()
    let name = try #require(value(after: "--name", in: commands[0].arguments))
    let arguments = commands.map(\.arguments)
    #expect(arguments.contains(ContainerInvocation.stop(name)))
    #expect(arguments.contains(ContainerInvocation.kill(name)))
    #expect(arguments.contains(ContainerInvocation.remove(name)))
    #expect(arguments.last == ContainerInvocation.listAll())
    #expect(try scratchChildren(fixture.root).isEmpty)
  }

  @Test func hostWatchdogBoundsWedgedControlCommandAndDisarmsAdmission() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let wedge = WedgeGate()
    defer { wedge.open() }
    let runner = ScriptedCommandRunner { command, history in
      switch command.arguments.first {
      case "run":
        writeCidfile(from: command.arguments)
        return commandResult(.exited(0))
      case "stop":
        // A wedged first cleanup rung: never returns and never observes cancellation
        // until the test releases it after the assertions.
        await wedge.wait()
        return commandResult(.exited(0))
      case "system":
        return jsonCommandResult(#"{"status":"running"}"#)
      case "list":
        let name = value(after: "--name", in: history[0].arguments) ?? "missing-name"
        return jsonCommandResult("[{\"id\":\"\(name)\"}]")
      default:
        return commandResult(.exited(0))
      }
    }
    let controlAllowance =
      ContainerBackend.lifecycleCommandTimeout + ContainerBackend.commandTeardownGrace
      + ContainerBackend.hostWatchdogSlack
    let backend = fixture.backend(
      commands: runner,
      watchdogSleep: { duration in
        // Fire instantly only for full-length lifecycle watchdogs: the wedged stop is
        // bounded while the foreground watchdog can never outrace the scripted run.
        if duration != controlAllowance {
          try await Task.sleep(for: duration)
        }
      }
    )
    await backend.setPreparedInitImageForTesting("ghcr.io/apple/containerization/vminit:1.1.0")

    // when
    let first = await backend.run(executionRequest())
    let second = await backend.run(executionRequest())

    // then
    guard case .startFailed(let reason) = first.terminationReason else {
      Issue.record("expected cleanup start failure")
      return
    }
    #expect(reason.contains("could not confirm container removal"))
    #expect(second.terminationReason == .unavailable(reason: "sandbox is not prepared"))
  }
}
