import Foundation
import Testing

@testable import ClawProcess

@Suite struct LocalCommandRunnerTests {
  @Test func adapterPreservesRawBytesAndExitStatus() async {
    // given
    let runner = SwiftSubprocessLocalCommandRunner(executablePath: "/bin/sh")
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
    let runner = SwiftSubprocessLocalCommandRunner(executablePath: "/bin/sh")
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

  @Test func inheritPolicyDeletesNamedKeysAndPrefixMatchesOnly() async {
    // given
    let runner = SwiftSubprocessLocalCommandRunner(
      executablePath: "/bin/sh",
      environmentForTesting: [
        "SSH_AUTH_SOCK": "/tmp/agent.sock",
        "CLAW_LLM_API_KEY": "secret",
        "CLAWFOOT": "present",
        "RUNNER_SENTINEL": "present",
      ]
    )
    let script = """
      printf '%s|%s|%s|%s' \
        "${SSH_AUTH_SOCK-unset}" \
        "${CLAW_LLM_API_KEY-unset}" \
        "${CLAWFOOT-unset}" \
        "${RUNNER_SENTINEL-unset}"
      """
    let command = testCommand(
      ["-c", script],
      environment: .inherit(removingKeys: ["SSH_AUTH_SOCK"], removingPrefixes: ["CLAW_"])
    )

    // when
    let result = await runner.run(command)

    // then
    #expect(result.termination == .exited(0))
    #expect(
      String(bytes: result.stdout.bytes, encoding: .utf8) == "unset|unset|present|present"
    )
  }

  @Test func prefixPolicyDropsAKeyThisProcessReallyInherited() async throws {
    // given — a key nothing injected, so the deletion has to come from enumerating the parent's
    // own environment. `env` is launched directly: a shell would regenerate a default PATH and
    // hide the removal.
    let parent = ProcessInfo.processInfo.environment
    #expect(parent["PATH"] != nil)
    let survivor = try #require(parent.keys.sorted().first { !$0.hasPrefix("PAT") })
    let runner = SwiftSubprocessLocalCommandRunner(executablePath: "/usr/bin/env")
    let command = testCommand(
      [],
      captureLimit: 64 * 1024,
      environment: .inherit(removingPrefixes: ["PAT"])
    )

    // when
    let result = await runner.run(command)

    // then
    #expect(result.termination == .exited(0))
    let printed = try #require(String(bytes: result.stdout.bytes, encoding: .utf8))
    let names = printed.split(separator: "\n").map { line in
      String(line.prefix { character in character != "=" })
    }
    #expect(!names.contains("PATH"))
    #expect(names.contains(survivor))
  }

  @Test func adapterRunsTheProgramInTheRequestedWorkingDirectory() async throws {
    // given
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-cwd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = SwiftSubprocessLocalCommandRunner(executablePath: "/bin/sh")
    let command = testCommand(["-c", "pwd -P"], workingDirectory: directory.path)

    // when
    let result = await runner.run(command)

    // then
    #expect(result.termination == .exited(0))
    let printed = try #require(String(bytes: result.stdout.bytes, encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // `pwd -P` reports the physical path, so the expectation has to resolve the temporary
    // directory's own symlinks the same way.
    let resolved = try #require(realpath(directory.path, nil))
    defer { free(resolved) }
    #expect(printed == String(cString: resolved))
  }

  @Test func programBudgetStartsAfterSpawnAndReturnsTypedTimeout() async throws {
    // given
    let (spawned, continuation) = AsyncStream.makeStream(of: Int32.self)
    let runner = SwiftSubprocessLocalCommandRunner(
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
    let runner = SwiftSubprocessLocalCommandRunner(
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
    let runner = SwiftSubprocessLocalCommandRunner(executablePath: "/bin/sh")
    // The backgrounded sleep inherits stdout (the asserted pipe); stderr only publishes its
    // PID so the test can reap the grandchild instead of orphaning a real 30-second sleep.
    let command = testCommand(["-c", "sleep 30 & echo $! >&2; printf child"], timeout: .seconds(2))

    // when
    let result = await runner.run(command)

    // then
    #expect(result.termination == .exited(0))
    #expect(String(bytes: result.stdout.bytes, encoding: .utf8) == "child")
    let pidText = try #require(String(bytes: result.stderr.bytes, encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let grandchild = try #require(Int32(pidText))
    // ESRCH just means the grandchild already exited; anything else is equally moot here.
    _ = kill(grandchild, SIGKILL)
  }
}

private func testCommand(
  _ arguments: [String],
  captureLimit: Int = 1024,
  timeout: Duration = .seconds(2),
  workingDirectory: String? = nil,
  environment: LocalCommandEnvironment = .inherit()
) -> LocalCommand {
  LocalCommand(
    arguments: arguments,
    timeout: timeout,
    captureLimit: captureLimit,
    teardownGracePeriod: .milliseconds(50),
    workingDirectory: workingDirectory,
    environment: environment
  )
}

private func firstValue(from stream: AsyncStream<Int32>) async throws -> Int32 {
  for await value in stream {
    return value
  }
  throw MissingSpawnError()
}

private struct MissingSpawnError: Error {}
