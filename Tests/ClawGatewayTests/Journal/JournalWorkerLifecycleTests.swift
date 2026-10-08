import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite
struct JournalWorkerLifecycleTests {
  @Test
  func runningServiceConsumesSynchronousHintsWithoutWaitingForTheTicker() async throws {
    // given
    let fixture = try JournalWorkerFixture()
    defer { fixture.removeFiles() }
    let ticking = AsyncGate()
    let entered = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let tickerClock = ScriptedClock { delay in
      #expect(delay == .seconds(60))
      ticking.open()
      await AsyncGate().wait()
      throw CancellationError()
    }
    let provider = SequenceProvider(
      [fixture.response],
      beforeResponse: {
        entered.open()
        await release.waitIgnoringCancellation()
      }
    )
    let worker = fixture.worker(provider: provider, sweepClock: tickerClock)
    let service = Task { try await worker.run() }
    defer { service.cancel() }
    guard await ticking.waitUntilOpen() else {
      Issue.record("Service did not start its ticker")
      return
    }
    await worker.sweep(now: fixture.now)
    _ = try fixture.seed(count: 1, at: fixture.now.addingTimeInterval(-86_400))

    // when
    worker.notifyPending()
    guard await entered.waitUntilOpen() else {
      Issue.record("Synchronous hint did not start pending work")
      return
    }
    release.open()
    await worker.sweep(now: fixture.now)
    await worker.shutdown()
    try await service.value

    // then
    #expect(await provider.requests.count == 1)
    #expect(try fixture.store.status(ownerUserID: 42, now: fixture.now).pendingCount == 0)
  }

  @Test
  func shutdownJoinsStartedInference() async throws {
    // given
    let fixture = try JournalWorkerFixture()
    defer { fixture.removeFiles() }
    _ = try fixture.seed(count: 11, at: fixture.now.addingTimeInterval(-86_400))
    let entered = AsyncGate()
    let cancelled = AsyncGate()
    let release = AsyncGate()
    let returned = AsyncGate()
    defer { release.open() }
    let provider = SequenceProvider(
      [fixture.response],
      beforeResponse: {
        entered.open()
        await withTaskCancellationHandler {
          await release.waitIgnoringCancellation()
          returned.open()
        } onCancel: {
          cancelled.open()
        }
      }
    )
    let ticking = AsyncGate()
    let tickerClock = ScriptedClock { delay in
      #expect(delay == .seconds(60))
      ticking.open()
      await AsyncGate().wait()
      throw CancellationError()
    }
    let worker = fixture.worker(provider: provider, sweepClock: tickerClock)
    worker.notifyPending()
    #expect(await provider.requests.isEmpty)
    let drain = Task { try await worker.run() }
    defer { drain.cancel() }
    guard await entered.waitUntilOpen() else {
      Issue.record("Provider did not start")
      return
    }
    #expect(await ticking.waitUntilOpen())
    let startedCallID = try #require(fixture.batches().first?.providerCallID)

    // when
    let shutdown = Task {
      await worker.shutdown()
      return (providerReturned: returned.isOpen, usageCallIDs: try fixture.usageCallIDs())
    }
    defer { shutdown.cancel() }
    guard await cancelled.waitUntilOpen() else {
      Issue.record("Shutdown did not cancel inference")
      return
    }
    #expect(!returned.isOpen)
    release.open()
    let joined = try await shutdown.value
    try await drain.value

    // then
    #expect(joined.providerReturned)
    #expect(joined.usageCallIDs == [startedCallID.rawValue])
    #expect(await provider.requests.count == 1)
    #expect(try fixture.store.status(ownerUserID: 42, now: fixture.now).pendingCount == 1)
    #expect(try fixture.store.canPublish(batchID: #require(fixture.batches().first?.id)) == false)
  }
}
