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
    let command = testCommand(["-c", script], captureLimit: 1024)

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
    let root = try makeTemporaryRoot(prefix: "claw-grandchild")
    defer { try? FileManager.default.removeItem(at: root) }
    let pipe = try makeGrandchildPipe(in: root)
    let grandchildPIDFile = root.appendingPathComponent("grandchild.pid")
    let runner = SwiftSubprocessRunner(
      executablePath: "/bin/sh",
      onSpawnForTesting: { processIdentifier in
        continuation.yield(processIdentifier)
      }
    )
    let script = """
      trap '' TERM
      (trap '' TERM; exec cat "$2") &
      grandchild=$!
      printf '%s\n' "$grandchild" > "$1"
      wait
      """
    let task = Task {
      await runner.run(
        testCommand(
          ["-c", script, "claw-subprocess-test", grandchildPIDFile.path, pipe.path]
        )
      )
    }
    defer {
      task.cancel()
      continuation.finish()
    }

    // when
    let processIdentifier = try await firstValue(from: spawned)
    defer { _ = kill(-processIdentifier, SIGKILL) }
    let grandchild = try #require(await readProcessIdentifier(from: grandchildPIDFile))
    task.cancel()
    let result = await task.value
    let grandchildBecameUnreachable = await processBecameUnreachable(grandchild)

    // then
    #expect(processIdentifier > 0)
    #expect(grandchild > 0)
    #expect(result.termination == .cancelled)
    #expect(result.processIdentifier == processIdentifier)
    #expect(grandchildBecameUnreachable)
  }

  @Test func childExitDoesNotWaitForGrandchildHoldingThePipe() async throws {
    // given
    let root = try makeTemporaryRoot(prefix: "claw-grandchild-pipe")
    defer { try? FileManager.default.removeItem(at: root) }
    let pipe = try makeGrandchildPipe(in: root)
    let runner = SwiftSubprocessRunner(executablePath: "/bin/sh")
    let command = testCommand([
      "-c", "cat \"$1\" & printf child", "claw-subprocess-test", pipe.path,
    ])

    // when
    let result = await runner.run(command)
    defer {
      if let processIdentifier = result.processIdentifier {
        _ = kill(-processIdentifier, SIGKILL)
      }
    }

    // then
    #expect(result.termination == .exited(0))
    #expect(String(bytes: result.stdout.bytes, encoding: .utf8) == "child")
  }
}

private func testCommand(
  _ arguments: [String],
  captureLimit: Int = 1024,
  timeout: Duration = boundedTestPollCeiling,
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
  await pollUntil {
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
  await pollUntil {
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

private func makeGrandchildPipe(in root: URL) throws -> URL {
  let pipe = root.appendingPathComponent("input.fifo")
  try #require(mkfifo(pipe.path, 0o600) == 0)
  return pipe
}
