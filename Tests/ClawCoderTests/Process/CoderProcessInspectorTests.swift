import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawCoder

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@Suite struct CoderProcessInspectorTests {
  @Test func recoveryRequiresMatchingIdentity() async throws {
    // given
    let fixture = ProcessFixture()
    defer { fixture.cleanup() }
    let launched = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let task = Task {
      defer { launched.open() }
      return await fixture.run(
        fixture.command(arguments: ["-c", "exec /bin/sleep 600"]),
        tracking: .job { event in
          try await fixture.record(event)
          if case .didLaunch = event {
            launched.open()
            await release.waitIgnoringCancellation()
          }
        },
        onStandardOutput: { _ in }
      )
    }
    defer { task.cancel() }
    await launched.wait()
    let receipt = try #require(fixture.receipt)
    let inspector = CoderProcessInspector()
    let mismatched = CoderProcessReceipt(
      launchID: receipt.launchID,
      phase: receipt.phase,
      hostBootID: receipt.hostBootID,
      pid: receipt.pid,
      pgid: receipt.pgid,
      birthIdentity: "different-birth"
    )
    let unreadable = CoderProcessReceipt(
      launchID: receipt.launchID,
      phase: receipt.phase,
      hostBootID: receipt.hostBootID,
      pid: receipt.pid,
      pgid: nil,
      birthIdentity: nil
    )
    let previousBoot = CoderProcessReceipt(
      launchID: receipt.launchID,
      phase: receipt.phase,
      hostBootID: UUID().uuidString,
      pid: receipt.pid,
      pgid: receipt.pgid,
      birthIdentity: receipt.birthIdentity
    )

    // when
    let owned = await inspector.inspect(receipt)
    let mismatch = await inspector.inspect(mismatched)
    let missing = await inspector.inspect(unreadable)
    let rebooted = await inspector.inspect(previousBoot)
    let stillOwned = await inspector.inspect(receipt)
    task.cancel()
    release.open()
    _ = await task.value
    let stopped = await inspector.inspect(receipt)

    // then
    #expect(owned == .liveOwned)
    #expect(mismatch == .unresolved)
    #expect(missing == .unresolved)
    #expect(rebooted == .stopped)
    #expect(stillOwned == .liveOwned)
    #expect(stopped == .stopped)
  }

  @Test func missingLeaderWithLiveDescendantIsUnresolved() async throws {
    // given
    let fixture = ProcessFixture()
    defer { fixture.cleanup() }
    let receipt = try await OrphanedProcessFixture.reapLeader(of: fixture)
    let pids = await fixture.pids
    try #require(pids.count == 2)
    let leader = try #require(receipt.pid)
    let child = try #require(pids.last)
    try #require(receipt.pgid == leader)
    try #require(kill(leader, 0) == -1 && errno == ESRCH)
    try #require(fixture.isLive(child))

    // when
    let observation = await CoderProcessInspector().inspect(receipt)

    // then
    #expect(observation == .unresolved)
    #expect(fixture.isLive(child))
  }
}
