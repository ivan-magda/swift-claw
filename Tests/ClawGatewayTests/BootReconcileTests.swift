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
      degradationText: Degradation.unfinished
    )
    #expect(replies.count == 1)

    let task = Task { try await dispatcher.run() }
    await transport.waitForSends(atLeast: 1)
    signal.finish()
    task.cancel()

    // then — the owner received the unfinished-run degradation, so the crash was never silent
    #expect(await transport.richSends.first?.markdown == Degradation.unfinished)
  }
}
