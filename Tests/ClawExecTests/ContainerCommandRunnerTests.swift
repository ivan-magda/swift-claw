import Foundation
import Testing

@testable import ClawExec

@Suite struct ContainerCommandRunnerTests {
  @Test func adapterPreservesRawBytesAndExitStatus() async {
    // given
    let runner = SwiftSubprocessContainerCommandRunner(executablePath: "/bin/sh")
    let command = testCommand(["-c", "printf '\\001out'; printf '\\377err' >&2; exit 7"])

    // when
    let result = await runner.run(command)

    // then
    #expect(result.termination == .exited(7))
    #expect(result.stdout.bytes == Data([0x01, 0x6f, 0x75, 0x74]))
    #expect(result.stderr.bytes == Data([0xff, 0x65, 0x72, 0x72]))
    #expect(result.stdout.totalBytes == 4)
    #expect(!result.stdout.truncated)
    #expect(result.processIdentifier != nil)
  }

  @Test func adapterDrainsBothFloodedStreamsAndKeepsIndependentPrefixes() async {
    // given
    let runner = SwiftSubprocessContainerCommandRunner(executablePath: "/bin/sh")
    let script = """
      count=0
      while [ "$count" -lt 4096 ]; do
        printf 'oooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo'
        printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' >&2
        count=$((count + 1))
      done
      """
    let command = testCommand(["-c", script], captureLimit: 1024, timeout: .seconds(5))

    // when
    let result = await runner.run(command)

    // then
    #expect(result.termination == .exited(0))
    #expect(result.stdout.bytes == Data(repeating: UInt8(ascii: "o"), count: 1024))
    #expect(result.stderr.bytes == Data(repeating: UInt8(ascii: "e"), count: 1024))
    #expect(result.stdout.totalBytes == 262_144)
    #expect(result.stderr.totalBytes == 262_144)
    #expect(result.stdout.truncated)
    #expect(result.stderr.truncated)
  }

  @Test func adapterDeletesAmbientSecuritySensitiveEnvironment() async {
    // given
    let runner = SwiftSubprocessContainerCommandRunner(
      executablePath: "/bin/sh",
      environmentForTesting: [
        "SSH_AUTH_SOCK": "/tmp/agent.sock",
        "CONTAINER_DEBUG": "1",
        "CONTAINER_DEFAULT_PLATFORM": "linux/amd64",
        "CLAW_RUNNER_SENTINEL": "present",
      ]
    )
    let script = """
      printf '%s|%s|%s|%s' \
        "${SSH_AUTH_SOCK-unset}" \
        "${CONTAINER_DEBUG-unset}" \
        "${CONTAINER_DEFAULT_PLATFORM-unset}" \
        "${CLAW_RUNNER_SENTINEL-unset}"
      """

    // when
    let result = await runner.run(testCommand(["-c", script]))

    // then
    #expect(result.termination == .exited(0))
    #expect(String(decoding: result.stdout.bytes, as: UTF8.self) == "unset|unset|unset|present")
  }

  @Test func programBudgetStartsAfterSpawnAndReturnsTypedTimeout() async throws {
    // given
    let (spawned, continuation) = AsyncStream.makeStream(of: Int32.self)
    let runner = SwiftSubprocessContainerCommandRunner(
      executablePath: "/bin/sh",
      onSpawnForTesting: { processIdentifier in
        continuation.yield(processIdentifier)
      }
    )
    let task = Task {
      await runner.run(
        testCommand(["-c", "trap '' TERM; while :; do :; done"], timeout: .milliseconds(50))
      )
    }

    // when
    let processIdentifier = try await firstValue(from: spawned)
    let result = await task.value
    continuation.finish()

    // then
    #expect(processIdentifier > 0)
    #expect(result.termination == .timedOut)
    #expect(result.processIdentifier == processIdentifier)
  }

  @Test func callerCancellationTearsDownTheCreatedProcessGroup() async throws {
    // given
    let (spawned, continuation) = AsyncStream.makeStream(of: Int32.self)
    let runner = SwiftSubprocessContainerCommandRunner(
      executablePath: "/bin/sh",
      onSpawnForTesting: { processIdentifier in
        continuation.yield(processIdentifier)
      }
    )
    let task = Task {
      await runner.run(
        testCommand(
          ["-c", "trap '' TERM; (trap '' TERM; while :; do :; done) & wait"],
          timeout: .seconds(30)
        )
      )
    }
    _ = try await firstValue(from: spawned)

    // when
    task.cancel()
    let result = await task.value
    continuation.finish()

    // then
    #expect(result.termination == .cancelled)
  }

  @Test func childExitDoesNotWaitForGrandchildHoldingThePipe() async throws {
    // given
    let runner = SwiftSubprocessContainerCommandRunner(executablePath: "/bin/sh")
    // The backgrounded sleep inherits stdout (the asserted pipe); stderr only publishes its
    // PID so the test can reap the grandchild instead of orphaning a real 30-second sleep.
    let command = testCommand(["-c", "sleep 30 & echo $! >&2; printf child"], timeout: .seconds(2))

    // when
    let result = await runner.run(command)

    // then
    #expect(result.termination == .exited(0))
    #expect(String(decoding: result.stdout.bytes, as: UTF8.self) == "child")
    let pidText = String(decoding: result.stderr.bytes, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let grandchild = try #require(Int32(pidText))
    // ESRCH just means the grandchild already exited; anything else is equally moot here.
    _ = kill(grandchild, SIGKILL)
  }
}

private func testCommand(
  _ arguments: [String],
  captureLimit: Int = 1024,
  timeout: Duration = .seconds(2)
) -> ContainerCommand {
  ContainerCommand(
    arguments: arguments,
    timeout: timeout,
    captureLimit: captureLimit,
    teardownGracePeriod: .milliseconds(50)
  )
}

private func firstValue(from stream: AsyncStream<Int32>) async throws -> Int32 {
  for await value in stream {
    return value
  }
  throw MissingSpawnError()
}

private struct MissingSpawnError: Error {}
