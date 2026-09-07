import ClawCore
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawCoder

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@Suite struct CoderCommandRunnerTests {
  @Test func cancellationJoinsSurvivingGroup() async throws {
    // given
    let fixture = ProcessFixture()
    defer { fixture.cleanup() }
    let task = Task {
      defer { fixture.ready.open() }
      return await CoderCommandRunner().run(
        fixture.command(),
        tracking: .job(record: fixture.record)
      ) {
        await fixture.output($0)
      }
    }
    defer { task.cancel() }
    await fixture.ready.wait()
    let pids = await fixture.pids
    try #require(pids.count == 2)
    let child = try #require(pids.last)

    // when
    task.cancel()
    let result = await task.value

    // then
    #expect(result.cancelled)
    #expect(!result.supervisionFailed)
    #expect(!result.timedOut)
    let cleanupResolved = result.cleanupResolved
    #expect(cleanupResolved)
    #expect(!fixture.isLive(child))
    #expect(fixture.stoppedAfterReap)
  }

  @Test(arguments: [false, true])
  func preservesTerminationStatus(signaled: Bool) async {
    // given
    let fixture = ProcessFixture()
    defer { fixture.cleanup() }
    let script = signaled ? "kill -TERM $$" : "exit 7"

    // when
    let result = await CoderCommandRunner().run(
      fixture.command(arguments: ["-c", script]),
      tracking: .preApprovalReadOnly,
      onStandardOutput: { _ in }
    )

    // then
    #expect(result.exitCode == (signaled ? nil : 7))
    #expect(result.signal == (signaled ? SIGTERM : nil))
    #expect(!result.supervisionFailed)
    let cleanupResolved = result.cleanupResolved
    #expect(cleanupResolved)
  }

  @Test func cancellationBeforeSpawn() async {
    // given
    let fixture = ProcessFixture()
    defer { fixture.cleanup() }
    let entered = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let task = Task {
      defer { entered.open() }
      return await CoderCommandRunner().run(
        fixture.command(),
        tracking: .job { event in
          try await fixture.record(event)
          if case .willLaunch = event {
            entered.open()
            await release.waitIgnoringCancellation()
          }
        },
        onStandardOutput: { _ in }
      )
    }
    defer { task.cancel() }
    await entered.wait()

    // when
    task.cancel()
    release.open()
    let result = await task.value

    // then
    #expect(result.cancelled)
    #expect(!result.supervisionFailed)
    #expect(fixture.launchedPID == nil)
    let cleanupResolved = result.cleanupResolved
    #expect(cleanupResolved)
  }

  @Test func cancellationDuringLaunchReceiptStopsChild() async throws {
    // given
    let fixture = ProcessFixture()
    defer { fixture.cleanup() }
    let entered = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let task = Task {
      defer { entered.open() }
      return await CoderCommandRunner().run(
        fixture.command(arguments: ["-c", "exec /bin/sleep 600"]),
        tracking: .job { event in
          try await fixture.record(event)
          if case .didLaunch = event {
            entered.open()
            await release.waitIgnoringCancellation()
          }
        },
        onStandardOutput: { _ in }
      )
    }
    defer { task.cancel() }
    await entered.wait()
    let pid = try #require(fixture.launchedPID)

    // when
    task.cancel()
    let exited = await fixture.waitForExit(pid)
    release.open()
    let result = await task.value

    // then
    #expect(exited)
    #expect(result.cancelled)
    #expect(!result.supervisionFailed)
    let cleanupResolved = result.cleanupResolved
    #expect(cleanupResolved)
  }

  @Test(arguments: CooperativeCallbackBoundary.allCases)
  func cancellationReachesCooperativeCallback(boundary: CooperativeCallbackBoundary) async {
    // given
    let fixture = ProcessFixture()
    defer { fixture.cleanup() }
    let callback = CooperativeCallback()
    let task = Task {
      defer { callback.entered.open() }
      return await CoderCommandRunner().run(
        fixture.command(),
        tracking: .job { event in
          try await fixture.record(event)
          switch (event, boundary) {
          case (.willLaunch, .willLaunch), (.didLaunch, .didLaunch):
            try await callback.suspend()
          default: break
          }
        }
      ) { data in
        await fixture.output(data)
        if boundary == .standardOutput, fixture.ready.isOpen {
          try await callback.suspend()
        }
      }
    }
    defer { task.cancel() }
    await callback.entered.wait()

    // when
    task.cancel()
    let result = await task.value

    // then
    #expect(callback.cancelled.isOpen)
    #expect(result.cancelled)
    #expect(!result.supervisionFailed)
    #expect(result.cleanupResolved)
  }

  @Test func deadlineReachesCooperativeCallback() async {
    // given
    let fixture = ProcessFixture()
    defer { fixture.cleanup() }
    let callback = CooperativeCallback()

    // when
    let result = await CoderCommandRunner().run(
      fixture.command(arguments: ["-c", "exec /bin/sleep 600"], timeout: .seconds(5)),
      tracking: .job { event in
        try await fixture.record(event)
        if case .didLaunch = event { try await callback.suspend() }
      },
      onStandardOutput: { _ in }
    )

    // then
    #expect(callback.entered.isOpen)
    #expect(callback.cancelled.isOpen)
    #expect(result.timedOut)
    #expect(!result.cancelled)
    #expect(!result.supervisionFailed)
    #expect(result.cleanupResolved)
    #expect(fixture.stoppedAfterReap)
  }

  @Test func failedLaunchReceiptCleansUp() async {
    // given
    let fixture = ProcessFixture()
    defer { fixture.cleanup() }

    // when
    let result = await CoderCommandRunner().run(
      fixture.command(),
      tracking: .job { event in
        try await fixture.record(event)
        if case .didLaunch = event { throw FixtureFailure.rejected }
      },
      onStandardOutput: { _ in }
    )

    // then
    let cleanupResolved = result.cleanupResolved
    #expect(cleanupResolved)
    #expect(result.supervisionFailed)
    #expect(!result.diagnostics.isEmpty)
    #expect(fixture.stoppedAfterReap)
  }

  @Test func failedOutputConsumerCleansUp() async {
    // given
    let fixture = ProcessFixture()
    defer { fixture.cleanup() }

    // when
    let result = await CoderCommandRunner().run(
      fixture.command(),
      tracking: .job(record: fixture.record)
    ) { data in
      await fixture.output(data)
      if fixture.ready.isOpen { throw FixtureFailure.rejected }
    }

    // then
    let cleanupResolved = result.cleanupResolved
    #expect(cleanupResolved)
    #expect(result.supervisionFailed)
    #expect(!result.diagnostics.isEmpty)
    #expect(fixture.stoppedAfterReap)
    #expect(result.exitCode == 0)
    let pids = await fixture.pids
    #expect(
      pids.allSatisfy { pid in
        !fixture.isLive(pid)
      }
    )
  }

  @Test func drainsBeyondDiagnosticLimit() async {
    // given
    let fixture = ProcessFixture()
    defer { fixture.cleanup() }
    let count = CoderCommandRunner.diagnosticByteLimit * 3
    let script = "head -c \(count) /dev/zero | tr '\\000' '\\377' >&2; printf done"

    // when
    let result = await CoderCommandRunner().run(
      fixture.command(arguments: ["-c", script]),
      tracking: .preApprovalReadOnly
    ) { data in
      await fixture.output(data)
    }

    // then
    let exitCode = result.exitCode
    let diagnosticCount = result.diagnostics.utf8.count
    #expect(exitCode == 0)
    #expect(diagnosticCount <= CoderCommandRunner.diagnosticByteLimit)
    #expect(diagnosticCount >= CoderCommandRunner.diagnosticByteLimit - 3)
    #expect(await fixture.text == "done")
    let cleanupResolved = result.cleanupResolved
    #expect(cleanupResolved)
  }
}
