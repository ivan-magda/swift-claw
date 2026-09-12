import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

/// The delivery identity moved off the run and onto the row's own `dedup_key`, so a message that
/// belongs to no run can be enqueued, sent and recorded like any other.
@Suite struct OutboxDeliveryIdentityTests {
  @Test func aLearningNoticeSurvivesInsertSendAndRestartWithoutDuplicating() async throws {
    // given — a notice row with no run
    let queue = try TestDatabase.make()
    let outbox = OutboxStoreGRDB(writer: queue)
    try OutboxFixture.seedNotice(
      in: queue,
      chunk: Self.notice(subjectDigest: "abc", ordinal: 0)
    )
    let transport = RecordingTransport()

    // when — the dispatcher drains, then the process restarts and drains again
    await Self.dispatcher(outbox: outbox, transport: transport).drainOnce()
    let restarted = OutboxStoreGRDB(writer: queue)
    await Self.dispatcher(outbox: restarted, transport: transport).drainOnce()

    // then — sent exactly once, and nothing is left behind for a third drain
    let sends = await transport.richSends
    #expect(sends.map(\.markdown) == ["candidate ready"])
    #expect(try restarted.pendingOutbound().isEmpty)
  }
}

// MARK: - Fixtures

private extension OutboxDeliveryIdentityTests {
  static func notice(subjectDigest: String, ordinal: Int) -> LearningNoticeChunk {
    LearningNoticeChunk(
      subjectDigest: subjectDigest,
      ordinal: ordinal,
      chatId: 42,
      payload: "candidate ready",
      payloadHash: "hash"
    )
  }

  static func dispatcher(
    outbox: OutboxStoreGRDB,
    transport: RecordingTransport
  ) -> OutboxDispatcher<ContinuousClock> {
    OutboxDispatcher(
      outbox: outbox,
      delivery: transport,
      signal: OutboxSignal(),
      logger: TestLog.silent
    )
  }
}
