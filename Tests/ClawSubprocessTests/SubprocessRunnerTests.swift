import ClawTestSupport
import Foundation
import Testing

@testable import ClawSubprocess

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

@Suite struct SubprocessRunnerTests {
  @Test func adapterPreservesRawBytesAndExitStatus() async {
    // given
    let runner = SwiftSubprocessRunner(executablePath: "/bin/sh")
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

  @Test func adapterForwardsStandardInputVerbatim() async {
    // given
    let runner = SwiftSubprocessRunner(executablePath: "/bin/cat")
    let standardInput = Data([0x00, 0x01, 0x7f, 0x80, 0xff])
    let command = testCommand(
      [],
      timeout: .seconds(30),
      standardInput: standardInput
    )

    // when
    let result = await runner.run(command)

    // then
    #expect(result.termination == .exited(0))
    #expect(result.stdout.bytes == standardInput)
    #expect(result.stdout.totalBytes == standardInput.count)
    #expect(!result.stdout.truncated)
  }

  @Test func adapterDrainsBothFloodedStreamsAndKeepsIndependentPrefixes() async {
    // given
    let runner = SwiftSubprocessRunner(executablePath: "/bin/sh")
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

  @Test func adapterAppliesTheCommandsEnvironmentRemovalPolicy() async {
    // given
    let runner = SwiftSubprocessRunner(
      executablePath: "/bin/sh",
      environmentForTesting: [
        "CLAW_REMOVE_FIRST": "first",
        "CLAW_REMOVE_SECOND": "second",
        "CLAW_KEEP_SENTINEL": "present",
      ]
    )
    let script = """
      printf '%s|%s|%s' \
        "${CLAW_REMOVE_FIRST-unset}" \
        "${CLAW_REMOVE_SECOND-unset}" \
        "${CLAW_KEEP_SENTINEL-unset}"
      """
    let command = testCommand(
      ["-c", script],
      environmentKeysToRemove: ["CLAW_REMOVE_FIRST", "CLAW_REMOVE_SECOND"]
    )

    // when
    let result = await runner.run(command)

    // then
    #expect(result.termination == .exited(0))
    #expect(String(bytes: result.stdout.bytes, encoding: .utf8) == "unset|unset|present")
  }

  @Test func programBudgetStartsAfterSpawnAndReturnsTypedTimeout() async throws {
    // given
    let (spawned, continuation) = AsyncStream.makeStream(of: Int32.self)
    let releaseSpawnBoundary = AsyncGate()
    let completed = CompletionFlag()
    let runner = SwiftSubprocessRunner(
      executablePath: "/bin/sh",
      onSpawnForTesting: { processIdentifier in
        continuation.yield(processIdentifier)
        await releaseSpawnBoundary.waitIgnoringCancellation()
      }
    )
    let task = Task {
      let result = await runner.run(
        testCommand(["-c", "trap '' TERM; while :; do :; done"], timeout: .zero)
      )
      await completed.markDone()
      return result
    }
    defer {
      releaseSpawnBoundary.open()
      task.cancel()
      continuation.finish()
    }

    // when
    let processIdentifier = try await firstValue(from: spawned)
    await Task.yield()
    let returnedBeforeSpawnBoundary = await completed.done
    releaseSpawnBoundary.open()
    let result = await task.value

    // then
    #expect(processIdentifier > 0)
    #expect(!returnedBeforeSpawnBoundary)
    #expect(result.termination == .timedOut)
    #expect(result.processIdentifier == processIdentifier)
  }

  @Test func callerCancellationTearsDownTheCreatedProcessGroup() async throws {
    // given
    let (spawned, continuation) = AsyncStream.makeStream(of: Int32.self)
    let grandchildPIDFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "claw-grandchild-\(UUID().uuidString).pid"
    )
    let runner = SwiftSubprocessRunner(
      executablePath: "/bin/sh",
      onSpawnForTesting: { processIdentifier in
        continuation.yield(processIdentifier)
      }
    )
    let script = """
      trap '' TERM
      (trap '' TERM; exec sleep 30) &
      grandchild=$!
      printf '%s\n' "$grandchild" > "$1"
      wait
      """
    let task = Task {
      await runner.run(
        testCommand(
          ["-c", script, "claw-subprocess-test", grandchildPIDFile.path],
          timeout: .seconds(30)
        )
      )
    }
    var leakedGrandchild: Int32?
    defer {
      task.cancel()
      continuation.finish()
      if let leakedGrandchild {
        _ = kill(leakedGrandchild, SIGKILL)
      }
      try? FileManager.default.removeItem(at: grandchildPIDFile)
    }

    // when
    let processIdentifier = try await firstValue(from: spawned)
    let grandchild = try #require(await readProcessIdentifier(from: grandchildPIDFile))
    leakedGrandchild = grandchild
    task.cancel()
    let result = await task.value
    let grandchildBecameUnreachable = await processBecameUnreachable(grandchild)
    if grandchildBecameUnreachable {
      leakedGrandchild = nil
    }

    // then
    #expect(processIdentifier > 0)
    #expect(grandchild > 0)
    #expect(result.termination == .cancelled)
    #expect(result.processIdentifier == processIdentifier)
    #expect(grandchildBecameUnreachable)
  }

  @Test func childExitDoesNotWaitForGrandchildHoldingThePipe() async throws {
    // given
    let runner = SwiftSubprocessRunner(executablePath: "/bin/sh")
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
  standardInput: Data = Data(),
  environmentKeysToRemove: [String] = []
) -> SubprocessCommand {
  SubprocessCommand(
    arguments: arguments,
    timeout: timeout,
    captureLimit: captureLimit,
    teardownGracePeriod: .milliseconds(50),
    standardInput: standardInput,
    environmentKeysToRemove: environmentKeysToRemove
  )
}

private func firstValue<Value>(from stream: AsyncStream<Value>) async throws -> Value {
  for await value in stream {
    return value
  }
  throw MissingSpawnError()
}

private func readProcessIdentifier(from file: URL) async -> Int32? {
  await pollUntil(timeout: .seconds(5)) {
    guard
      let data = try? Data(contentsOf: file),
      let text = String(bytes: data, encoding: .utf8),
      let processIdentifier = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
      processIdentifier > 0
    else {
      return nil
    }
    return processIdentifier
  }
}

private func processBecameUnreachable(_ processIdentifier: Int32) async -> Bool {
  await pollUntil(timeout: .seconds(5)) {
    #if canImport(Glibc)
      if let stat = try? String(
        contentsOfFile: "/proc/\(processIdentifier)/stat",
        encoding: .utf8
      ),
        let commandEnd = stat.lastIndex(of: ")"),
        stat[stat.index(after: commandEnd)...].split(separator: " ").first == "Z"
      {
        return true
      }
    #endif
    errno = 0
    return kill(processIdentifier, 0) == -1 && errno == ESRCH ? true : nil
  } ?? false
}

private struct MissingSpawnError: Error {}
