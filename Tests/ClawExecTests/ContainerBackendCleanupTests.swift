import ClawCore
import Foundation
import Testing

@testable import ClawExec

@Suite struct ContainerBackendCleanupTests {
  @Test func failedCleanupDisarmsAdmissionUntilNextPrepare() async throws {
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
    let first = await backend.run(executionRequest())
    let commandsAfterFirst = await runner.recorded().count
    let second = await backend.run(executionRequest())

    // then
    guard case .startFailed(let reason) = first.terminationReason else {
      Issue.record("expected cleanup start failure")
      return
    }
    #expect(reason.contains("could not confirm container removal"))
    #expect(second.terminationReason == .unavailable(reason: "sandbox is not prepared"))
    #expect(await runner.recorded().count == commandsAfterFirst)
  }

  @Test func failedCleanupAlsoRefusesRunsAlreadyQueuedBehindIt() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let gate = AsyncGate()
    let runner = ScriptedCommandRunner { command, history in
      if command.arguments.first == "run" {
        writeCidfile(from: command.arguments)
        await gate.wait()
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
    let first = Task { await backend.run(executionRequest()) }
    await runner.waitForCount(1)
    let second = Task { await backend.run(executionRequest()) }
    await waitForQueuedCount(2, backend: backend)

    // when
    await gate.open()
    let firstResult = await first.value
    let secondResult = await second.value

    // then
    guard case .startFailed(let reason) = firstResult.terminationReason else {
      Issue.record("expected cleanup start failure")
      return
    }
    #expect(reason.contains("could not confirm container removal"))
    #expect(secondResult.terminationReason == .unavailable(reason: "sandbox is not prepared"))
    #expect(await runner.recorded().filter { $0.arguments.first == "run" }.count == 1)
  }
}
