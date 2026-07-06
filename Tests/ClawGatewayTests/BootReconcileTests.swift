import ClawCore
import ClawData
import Foundation
import Logging
import Testing

@testable import ClawGateway

/// Proves the no-silence guarantee (F22) end-to-end: a run that crashed mid-turn (left RUNNING with
/// nothing delivered) is swept to FAILED at boot, which enqueues a degradation reply, and the
/// dispatcher's boot drain then delivers it to the owner.
@Suite struct BootReconcileTests {
  @Test func crashMidTurnYieldsABootDegradationReply() async throws {
    // given — a RUNNING run with no outbox row: the daemon died mid-turn, owner heard nothing
    let fixture = try makeSeededFixture()
    let transport = RecordingTransport()
    let signal = OutboxSignal()
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      transport: transport,
      signal: signal,
      logger: TestLog.silent
    )

    // when — boot reconcile sweeps the orphan to FAILED and enqueues the degradation, then the
    // dispatcher starts and its boot drain delivers what reconcile just enqueued
    let replies = try fixture.runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: Degradation.unfinished,
      heartbeatNoticeChatId: nil
    )
    #expect(replies.count == 1)

    let task = Task { try await dispatcher.run() }
    await transport.waitForSends(atLeast: 1)
    signal.finish()
    task.cancel()

    // then — the owner received the unfinished-run degradation, so the crash was never silent
    #expect(await transport.richSends.first?.markdown == Degradation.unfinished)
  }

  @Test func reconcileLeavesDeliveredAndCompletedRunsUntouched() async throws {
    // given — a terminal DONE run and a RUNNING run whose only outbox row was already SENT; neither
    // is an unfinished orphan, so the no-silence sweep has nothing to announce
    let fixture = try makeHealthyRunsFixture()
    let reconcileNow = Date()
    let beforeHealth = try fixture.runs.runsHealth(now: reconcileNow)

    // when — the same boot sweep the crash-mid-turn test exercises
    let replies = try fixture.runs.reconcileRunsAtBoot(
      now: reconcileNow,
      degradationText: Degradation.unfinished,
      heartbeatNoticeChatId: nil
    )

    // then — no degradation reply is produced or persisted for either healthy run, and the DONE
    // run is left exactly as it was (its last-success timestamp is unchanged)
    let afterHealth = try fixture.runs.runsHealth(now: reconcileNow)
    #expect(replies.isEmpty)
    #expect(try fixture.outbox.pendingOutbound().isEmpty)
    #expect(beforeHealth.inFlight == 1)
    #expect(afterHealth.inFlight == 0)
    #expect(afterHealth.lastSuccessAt == beforeHealth.lastSuccessAt)
  }
}
