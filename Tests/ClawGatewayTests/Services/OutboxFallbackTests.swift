import ClawCore
import ClawData
import Foundation
import Logging
import Testing

@testable import ClawGateway

/// Exercises the rich-send path and the plain fallback on a rich-send error (F8), over the real
/// outbox store.
@Suite struct OutboxFallbackTests {
  private struct Fixture {
    let outbox: OutboxStoreGRDB
    let runId: Int64
    let chatId: Int64
  }

  /// Seeds a session + run (so the `run_id` FK holds) and one PENDING `"**hi**"` outbound row,
  /// exactly as a committed turn would.
  private func makeFixtureWithPendingHi() throws -> Fixture {
    let seeded = try makeSeededFixture()
    _ = try seeded.outbox.claimOutbound(
      runId: seeded.runId,
      stepIndex: 0,
      chatId: seeded.chatId,
      payload: "**hi**",
      payloadHash: "hash"
    )
    return Fixture(outbox: seeded.outbox, runId: seeded.runId, chatId: seeded.chatId)
  }

  private func makeDispatcher(
    _ fixture: Fixture,
    transport: RecordingTransport
  ) -> OutboxDispatcher {
    OutboxDispatcher(
      outbox: fixture.outbox,
      transport: transport,
      signal: OutboxSignal(),
      logger: TestLog.silent
    )
  }

  @Test func usesSendRichMessage() async throws {
    // given — a clean transport
    let fixture = try makeFixtureWithPendingHi()
    let transport = RecordingTransport()
    let dispatcher = makeDispatcher(fixture, transport: transport)

    // when
    await dispatcher.drainOnce()

    // then — delivered via the rich path, never the plain one
    let firstRich = try #require(await transport.richSends.first)
    #expect(firstRich.markdown == "**hi**")
    #expect(await transport.sent.isEmpty)
    #expect(try fixture.outbox.pendingOutbound().isEmpty)
  }

  @Test func richErrorFallsBackToPlainSendMessage() async throws {
    // given — every rich send fails, so the dispatcher must fall back to plain
    let fixture = try makeFixtureWithPendingHi()
    let transport = RecordingTransport(richError: .apiError(code: 400, description: "bad markdown"))
    let dispatcher = makeDispatcher(fixture, transport: transport)

    // when
    await dispatcher.drainOnce()

    // then — the same payload landed as plain text and the row is no longer PENDING
    let firstSent = try #require(await transport.sent.first)
    #expect(firstSent.text == "**hi**")
    #expect(try fixture.outbox.pendingOutbound().isEmpty)
  }
}
