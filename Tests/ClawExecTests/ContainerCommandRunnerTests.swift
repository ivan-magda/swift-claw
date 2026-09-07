import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawExec

@Suite struct ContainerCommandRunnerTests {
  @Test func adapterPreservesRawBytesAndExitStatus() async {
    // given
    let runner = testRunner(executablePath: "/bin/sh")
    let command = testCommand(["-c", "printf '\\001out'; printf '\\377err' >&2; exit 7"])

    // when
    let result = await runner.runWithWatchdog(command)

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
    let runner = testRunner(executablePath: "/bin/sh")
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
    let result = await runner.runWithWatchdog(command)

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
    let runner = testRunner(
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
    let result = await runner.runWithWatchdog(testCommand(["-c", script]))

    // then
    #expect(result.termination == .exited(0))
    #expect(String(bytes: result.stdout.bytes, encoding: .utf8) == "unset|unset|unset|present")
  }

  @Test func deadlineAfterSpawnReturnsTypedTimeout() async throws {
    // given
    let spawned = ClawTestSupport.AsyncGate()
    let deadline = ClawTestSupport.AsyncGate()
    let launchedPID = Mutex<Int32?>(nil)
    let runner = testRunner(
      executablePath: "/bin/sh",
      onSpawnForTesting: { processIdentifier in
        launchedPID.withLock { value in
          value = processIdentifier
        }
        spawned.open()
      },
      deadline: deadline
    )
    let task = Task {
      await runner.runWithWatchdog(
        testCommand(["-c", "trap '' TERM; while :; do :; done"])
      )
    }
    defer { task.cancel() }
    let didSpawn = await spawned.waitUntilOpen()

    // when
    deadline.open()
    if !didSpawn { task.cancel() }
    let result = await task.value

    // then
    #expect(didSpawn)
    #expect(result.termination == .timedOut)
    let processIdentifier = try #require(
      launchedPID.withLock { value in
        value
      }
    )
    #expect(processIdentifier > 0)
    #expect(result.processIdentifier == processIdentifier)
  }

  @Test func callerCancellationTearsDownTheCreatedProcessGroup() async {
    // given
    let spawned = ClawTestSupport.AsyncGate()
    let runner = testRunner(
      executablePath: "/bin/sh",
      onSpawnForTesting: { _ in
        spawned.open()
      }
    )
    let task = Task {
      await runner.runWithWatchdog(
        testCommand(
          ["-c", "trap '' TERM; (trap '' TERM; while :; do :; done) & wait"],
          timeout: .seconds(30)
        )
      )
    }
    defer { task.cancel() }
    let didSpawn = await spawned.waitUntilOpen()

    // when
    task.cancel()
    let result = await task.value

    // then
    #expect(didSpawn)
    #expect(result.termination == .cancelled)
  }

  @Test func childExitDoesNotWaitForGrandchildHoldingThePipe() async throws {
    // given
    let root = try makeTemporaryRoot(prefix: "container-grandchild")
    let pidFile = root.appendingPathComponent("pid")
    defer {
      let text = try? String(contentsOf: pidFile, encoding: .utf8)
      let pid = text.flatMap { value in
        Int32(value.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      if let pid { _ = kill(pid, SIGKILL) }
      try? FileManager.default.removeItem(at: root)
    }
    let runner = testRunner(executablePath: "/bin/sh")
    let command = testCommand([
      "-c", "sleep 600 & echo $! > \"$1\"; printf child", "fixture", pidFile.path,
    ])

    // when
    let result = await runner.runWithWatchdog(command)

    // then
    #expect(result.termination == .exited(0))
    #expect(String(bytes: result.stdout.bytes, encoding: .utf8) == "child")
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

private func testRunner(
  executablePath: String,
  environmentForTesting: [String: String] = [:],
  onSpawnForTesting: @Sendable @escaping (Int32) -> Void = { _ in },
  deadline: ClawTestSupport.AsyncGate = ClawTestSupport.AsyncGate()
) -> SwiftSubprocessContainerCommandRunner {
  SwiftSubprocessContainerCommandRunner(
    executablePath: executablePath,
    environmentForTesting: environmentForTesting,
    onSpawnForTesting: onSpawnForTesting,
    deadlineSleep: { _ in
      await deadline.wait()
      try Task.checkCancellation()
    }
  )
}

// MARK: - Completion watchdog

private extension SwiftSubprocessContainerCommandRunner {
  func runWithWatchdog(_ command: ContainerCommand) async -> ContainerCommandResult {
    await withTestWatchdog(
      onTimeout: {
        Issue.record("Container command did not complete before its watchdog.")
      },
      {
        await run(command)
      }
    )
  }
}
