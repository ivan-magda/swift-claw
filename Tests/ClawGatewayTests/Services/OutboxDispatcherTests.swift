import ClawCore
import ClawData
import Foundation
import Logging
import Testing

@testable import ClawGateway

/// Delegates to a real outbox store but fails every `markSent` — exercises the
/// send-succeeded-but-record-failed path, where the row must stay PENDING for re-send.
private struct MarkSentFailingOutbox: OutboxStore {
  let base: OutboxStoreGRDB

  func claimOutbound(runId: Int64, chunk: OutboxChunk) throws(StoreError) -> Bool {
    try base.claimOutbound(runId: runId, chunk: chunk)
  }

  func claimOutboundIfRunActive(runId: Int64, chunk: OutboxChunk) throws(StoreError) -> Bool {
    try base.claimOutboundIfRunActive(runId: runId, chunk: chunk)
  }

  func markSent(
    runId: Int64,
    stepIndex: Int,
    telegramMessageId: Int64,
    now: Date
  ) throws(StoreError) {
    throw StoreError.diskFull
  }

  func pendingOutbound() throws(StoreError) -> [OutboxRow] { try base.pendingOutbound() }
}

/// Records the `replyMarkup` argument the dispatcher passes to each send overload. Implements the
/// reply-markup overloads directly (rather than the throwing default) so the keyboard is captured.
private actor ReplyMarkupSpy: MessageDelivery {
  private(set) var richMarkups: [String?] = []
  private(set) var plainMarkups: [String?] = []
  private let failRich: Bool

  init(failRich: Bool = false) {
    self.failRich = failRich
  }

  func sendMessage(chatId: Int64, text: String) async throws -> Int64 { 1 }

  func sendRichMessage(chatId: Int64, markdown: String) async throws -> Int64 { 1 }

  func sendMessage(chatId: Int64, text: String, replyMarkup: String?) async throws -> Int64 {
    plainMarkups.append(replyMarkup)
    return 1
  }

  func sendRichMessage(
    chatId: Int64,
    markdown: String,
    replyMarkup: String?
  ) async throws -> Int64 {
    if failRich {
      throw TelegramError.transport("rich down")
    }
    richMarkups.append(replyMarkup)
    return 1
  }
}

@Suite struct OutboxDispatcherTests {
  private struct Fixture {
    let outbox: OutboxStoreGRDB
    let runId: Int64
    let chatId: Int64
  }

  private func makeFixture() throws -> Fixture {
    let seeded = try makeSeededFixture()
    return Fixture(outbox: seeded.outbox, runId: seeded.runId, chatId: seeded.chatId)
  }

  /// Enqueues a PENDING outbound row via the real claim path (as a committed turn would).
  private func seedPending(_ fixture: Fixture, stepIndex: Int = 0, payload: String) throws {
    _ = try fixture.outbox.claimOutbound(
      runId: fixture.runId,
      chunk: OutboxChunk(
        stepIndex: stepIndex,
        chatId: fixture.chatId,
        payload: payload,
        payloadHash: "hash"
      )
    )
  }

  @Test func drainSendsPendingRowsAndMarksThemSent() async throws {
    // given — one PENDING row and a transport that sends cleanly
    let fixture = try makeFixture()
    try seedPending(fixture, payload: "hello")
    let transport = RecordingTransport()
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: transport,
      signal: OutboxSignal(),
      logger: TestLog.silent
    )

    // when
    await dispatcher.drainOnce()

    // then — the row was delivered (via the rich path) and is no longer PENDING
    #expect(await transport.richSends.first?.markdown == "hello")
    #expect(try fixture.outbox.pendingOutbound().isEmpty)
  }

  @Test func sendFailureLeavesRowPendingForRetry() async throws {
    // given — the transport fails every send: rich and the plain fallback both error out
    let fixture = try makeFixture()
    try seedPending(fixture, payload: "hello")
    let transport = RecordingTransport(
      sendError: .transport("down"),
      richError: .transport("down")
    )
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: transport,
      signal: OutboxSignal(),
      logger: TestLog.silent
    )

    // when
    await dispatcher.drainOnce()

    // then — never marked SENT, so it stays PENDING for the next drain (at-least-once)
    #expect(try fixture.outbox.pendingOutbound().count == 1)
  }

  @Test func bootDrainRecoversRowsCommittedByAPriorRun() async throws {
    // given — a row already PENDING before the dispatcher starts (a prior run committed but never
    // sent it); no poke will fire, so only the boot drain can deliver it
    let fixture = try makeFixture()
    try seedPending(fixture, payload: "recovered")
    let transport = RecordingTransport()
    let signal = OutboxSignal()
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: transport,
      signal: signal,
      logger: TestLog.silent
    )

    // when — run the service; its boot drain delivers the pre-committed row, then we stop it
    let task = Task { try await dispatcher.run() }
    await transport.waitForSends(atLeast: 1)
    signal.finish()
    task.cancel()

    // then
    #expect(await transport.richSends.contains { $0.markdown == "recovered" })
  }

  @Test func midBatchSendFailureStopsAndLeavesLaterRowsPendingInOrder() async throws {
    // given — three ordered chunks; the transport fails the second send
    let fixture = try makeFixture()
    try seedPending(fixture, stepIndex: 0, payload: "first")
    try seedPending(fixture, stepIndex: 1, payload: "second")
    try seedPending(fixture, stepIndex: 2, payload: "third")
    let transport = RecordingTransport(failSendAtAttempt: 2)
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: transport,
      signal: OutboxSignal(),
      logger: TestLog.silent
    )

    // when
    await dispatcher.drainOnce()

    // then — only the first chunk went out; the failed chunk and the one after it stay PENDING in
    // order, never sent ahead (the break preserves multi-chunk delivery order)
    let deliveredMarkdown = await transport.richSends.map { $0.markdown }
    #expect(deliveredMarkdown == ["first"])
    let pendingPayloads = try fixture.outbox.pendingOutbound().map(\.payload)
    #expect(pendingPayloads == ["second", "third"])
  }

  @Test func sendSucceedsButMarkSentFailsLeavesRowPendingForResend() async throws {
    // given — the send will succeed but recording it fails (disk full)
    let fixture = try makeFixture()
    try seedPending(fixture, payload: "hello")
    let transport = RecordingTransport()
    let dispatcher = OutboxDispatcher(
      outbox: MarkSentFailingOutbox(base: fixture.outbox),
      delivery: transport,
      signal: OutboxSignal(),
      logger: TestLog.silent
    )

    // when
    await dispatcher.drainOnce()

    // then — it was delivered, but stays PENDING and re-sends next drain (accepted at-least-once
    // duplicate)
    let deliveredMarkdown = await transport.richSends.map { $0.markdown }
    #expect(deliveredMarkdown == ["hello"])
    #expect(try fixture.outbox.pendingOutbound().count == 1)
  }

  @Test func dispatcherForwardsReplyMarkupOnTheRichSend() async throws {
    // given — a PENDING row carrying an inline keyboard
    let fixture = try makeFixture()
    let markup = "{\"inline_keyboard\":[[{\"text\":\"Approve\",\"callback_data\":\"apr:x:y\"}]]}"
    _ = try fixture.outbox.claimOutbound(
      runId: fixture.runId,
      chunk: OutboxChunk(
        stepIndex: 0,
        chatId: fixture.chatId,
        payload: "prompt",
        payloadHash: "h",
        replyMarkup: markup
      )
    )
    let spy = ReplyMarkupSpy()
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: spy,
      signal: OutboxSignal(),
      logger: TestLog.silent
    )

    // when
    await dispatcher.drainOnce()

    // then — the keyboard rode the rich send
    #expect(await spy.richMarkups == [markup])
  }

  @Test func dispatcherForwardsReplyMarkupOnThePlainFallback() async throws {
    // given — the rich send fails, forcing the plain fallback
    let fixture = try makeFixture()
    let markup = "{\"inline_keyboard\":[[{\"text\":\"Approve\",\"callback_data\":\"apr:x:y\"}]]}"
    _ = try fixture.outbox.claimOutbound(
      runId: fixture.runId,
      chunk: OutboxChunk(
        stepIndex: 0,
        chatId: fixture.chatId,
        payload: "prompt",
        payloadHash: "h",
        replyMarkup: markup
      )
    )
    let spy = ReplyMarkupSpy(failRich: true)
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: spy,
      signal: OutboxSignal(),
      logger: TestLog.silent
    )

    // when
    await dispatcher.drainOnce()

    // then — the same keyboard rode the plain fallback
    #expect(await spy.plainMarkups == [markup])
  }
}
