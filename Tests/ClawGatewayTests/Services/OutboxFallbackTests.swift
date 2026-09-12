import ClawCore
import ClawData
import ClawTestSupport
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

  /// Commits a completed turn with one PENDING `"**hi**"` reply.
  private func makeFixtureWithPendingHi() throws -> Fixture {
    let seeded = try makeSeededFixture()
    try OutboxFixture.commitReply(
      in: seeded.writer,
      runId: seeded.runId,
      chunks: [
        OutboxChunk(
          stepIndex: 0,
          chatId: seeded.chatId,
          payload: "**hi**",
          payloadHash: "hash"
        )
      ]
    )
    return Fixture(outbox: seeded.outbox, runId: seeded.runId, chatId: seeded.chatId)
  }

  private func makeDispatcher(
    _ fixture: Fixture,
    transport: RecordingTransport
  ) -> OutboxDispatcher<ContinuousClock> {
    OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: transport,
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
