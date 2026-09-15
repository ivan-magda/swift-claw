import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Synchronization
import Testing

@testable import ClawGateway

/// Delegates to a real outbox store but fails every `markSent` — exercises the
/// send-succeeded-but-record-failed path, where the row must stay PENDING for re-send.
private struct MarkSentFailingOutbox: OutboxStore {
  let base: OutboxStoreGRDB

  func markSent(deliveryKey: String, telegramMessageID: Int64, now: Date) throws(StoreError) {
    throw StoreError.diskFull
  }

  func pendingOutbound() throws(StoreError) -> [OutboxRow] {
    try base.pendingOutbound()
  }
}

/// Records every send the dispatcher makes — its target, its `replyMarkup` and its payload — and
/// answers each one from a per-chat script, so a test can throttle one chat while another delivers.
/// The keyboardless spellings are extension conveniences, so implementing the requirements captures
/// every send either way.
private actor DeliverySpy: MessageDelivery {
  /// How the spy answers a send addressed to a given chat.
  enum Outcome: Sendable {
    /// Throws Telegram's 429 for the first `times` sends to the chat, then delivers.
    case floodControl(retryAfter: Int, times: Int)
    /// Fails the rich send and the plain fallback alike — a genuinely undeliverable chat.
    case unreachable
  }

  private(set) var richMarkups: [String?] = []
  private(set) var plainMarkups: [String?] = []
  private(set) var targets: [DeliveryTarget] = []
  private(set) var deliveredPayloads: [String] = []
  private(set) var richAttempts: [Int64] = []
  private(set) var plainAttempts: [Int64] = []
  private let failRich: Bool
  private var outcomes: [Int64: Outcome]

  init(failRich: Bool = false, outcomes: [Int64: Outcome] = [:]) {
    self.failRich = failRich
    self.outcomes = outcomes
  }

  func sendMessage(
    to target: DeliveryTarget,
    text: String,
    replyMarkup: String?
  ) async throws -> Int64 {
    plainAttempts.append(target.chatID)
    try answer(for: target.chatID)
    plainMarkups.append(replyMarkup)
    targets.append(target)
    deliveredPayloads.append(text)
    return 1
  }

  func sendRichMessage(
    to target: DeliveryTarget,
    markdown: String,
    replyMarkup: String?
  ) async throws -> Int64 {
    richAttempts.append(target.chatID)
    try answer(for: target.chatID)
    if failRich {
      throw TelegramError.transport("rich down")
    }
    richMarkups.append(replyMarkup)
    targets.append(target)
    deliveredPayloads.append(markdown)
    return 1
  }

  private func answer(for chatID: Int64) throws {
    switch outcomes[chatID] {
    case .none:
      return
    case .some(.unreachable):
      throw TelegramError.transport("chat \(chatID) down")
    case .some(.floodControl(let retryAfter, let times)):
      guard times > 0 else {
        return
      }
      outcomes[chatID] = .floodControl(retryAfter: retryAfter, times: times - 1)
      throw TelegramError.floodControl(retryAfter: retryAfter)
    }
  }
}

/// Holds the dispatcher's own `retry_after` wait parked for as long as the test wants, so virtual
/// time moves only when the test advances it. Any other sleep on this clock elapses at once, which
/// is how a test walks the clock past a hold without waiting for one.
private final class RetryWaitHold: Sendable {
  /// Opens once the dispatcher has asked to sleep out its hold.
  let waitStarted = AsyncGate()

  private let retryAfter: Duration
  private let released = AsyncGate()
  private let requested = Mutex<[Duration]>([])

  init(retryAfter: Duration) {
    self.retryAfter = retryAfter
  }

  var clock: ScriptedClock {
    ScriptedClock { [self] delay in
      requested.withLock { delays in
        delays.append(delay)
      }
      guard delay == retryAfter else {
        return
      }
      waitStarted.open()
      await released.wait()
    }
  }

  var requestedDelays: [Duration] {
    requested.withLock { delays in
      delays
    }
  }

  func release() {
    released.open()
  }
}

@Suite
struct OutboxDispatcherTests {
  private struct Fixture {
    let writer: any DatabaseWriter
    let outbox: OutboxStoreGRDB
    let runID: Int64
    let chatID: Int64
  }

  private func makeFixture() throws -> Fixture {
    let seeded = try makeSeededFixture()
    return Fixture(
      writer: seeded.writer,
      outbox: seeded.outbox,
      runID: seeded.runID,
      chatID: seeded.chatID
    )
  }

  private func seedPending(
    _ fixture: Fixture,
    payloads: [String],
    replyMarkup: String? = nil
  ) throws {
    try seedPending(
      in: fixture.writer,
      runID: fixture.runID,
      chatID: fixture.chatID,
      payloads: payloads,
      replyMarkup: replyMarkup
    )
  }

  private func seedPending(_ fixture: Fixture, payload: String) throws {
    try seedPending(fixture, payloads: [payload])
  }

  private func seedPending(
    in writer: any DatabaseWriter,
    runID: Int64,
    chatID: Int64,
    payloads: [String],
    replyMarkup: String? = nil
  ) throws {
    try OutboxFixture.commitReply(
      in: writer,
      runID: runID,
      chunks: payloads.enumerated().map { index, payload in
        OutboxChunk(
          stepIndex: index,
          chatID: chatID,
          payload: payload,
          payloadHash: ContentHash.fnv1a(payload),
          replyMarkup: replyMarkup
        )
      }
    )
  }

  /// One PENDING row for each of two chats, the first chat's run seeded first so the drain reaches
  /// its row first — the shape a per-chat failure has to be judged on.
  private struct TwoChatFixture {
    let outbox: OutboxStoreGRDB
    let firstChatID: Int64
    let secondChatID: Int64
  }

  private func makeTwoChatFixture(
    firstPayload: String,
    secondPayload: String
  ) throws -> TwoChatFixture {
    let firstChatID: Int64 = -1_001
    let secondChatID: Int64 = -1_002
    let seeded = try makeSeededFixture(chatID: firstChatID)
    let secondRunID = try seedRun(in: seeded.writer, chatID: secondChatID, updateID: 2)
    try seedPending(
      in: seeded.writer,
      runID: seeded.runID,
      chatID: firstChatID,
      payloads: [firstPayload]
    )
    try seedPending(
      in: seeded.writer,
      runID: secondRunID,
      chatID: secondChatID,
      payloads: [secondPayload]
    )
    return TwoChatFixture(
      outbox: seeded.outbox,
      firstChatID: firstChatID,
      secondChatID: secondChatID
    )
  }

  @Test
  func drainSendsPendingRowsAndMarksThemSent() async throws {
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

  @Test
  func sendFailureLeavesRowPendingForRetry() async throws {
    // given — the transport fails every send: rich and the plain fallback both error out
    let fixture = try makeFixture()
    try seedPending(fixture, payload: "hello")
    let transport = RecordingTransport(sendError: .transport("down"), richError: .transport("down"))
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

  @Test
  func bootDrainRecoversRowsCommittedByAPriorRun() async throws {
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
    let task = Task {
      try await dispatcher.run()
    }
    await transport.waitForSends(atLeast: 1)
    signal.finish()
    task.cancel()

    // then
    #expect(
      await transport.richSends.contains {
        $0.markdown == "recovered"
      }
    )
  }

  @Test
  func midBatchSendFailureStopsAndLeavesLaterRowsPendingInOrder() async throws {
    // given — three ordered chunks; the transport fails the second send
    let fixture = try makeFixture()
    try seedPending(fixture, payloads: ["first", "second", "third"])
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
    let deliveredMarkdown = await transport.richSends.map {
      $0.markdown
    }
    #expect(deliveredMarkdown == ["first"])
    let pendingPayloads = try fixture.outbox.pendingOutbound().map(\.payload)
    #expect(pendingPayloads == ["second", "third"])
  }

  @Test
  func sendSucceedsButMarkSentFailsLeavesRowPendingForResend() async throws {
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
    let deliveredMarkdown = await transport.richSends.map {
      $0.markdown
    }
    #expect(deliveredMarkdown == ["hello"])
    #expect(try fixture.outbox.pendingOutbound().count == 1)
  }

  @Test
  func dispatcherForwardsReplyMarkupOnTheRichSend() async throws {
    // given — a PENDING row carrying an inline keyboard
    let fixture = try makeFixture()
    let markup = "{\"inline_keyboard\":[[{\"text\":\"Approve\",\"callback_data\":\"apr:x:y\"}]]}"
    try seedPending(fixture, payloads: ["prompt"], replyMarkup: markup)
    let spy = DeliverySpy()
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

  @Test
  func dispatcherForwardsReplyMarkupOnThePlainFallback() async throws {
    // given — the rich send fails, forcing the plain fallback
    let fixture = try makeFixture()
    let markup = "{\"inline_keyboard\":[[{\"text\":\"Approve\",\"callback_data\":\"apr:x:y\"}]]}"
    try seedPending(fixture, payloads: ["prompt"], replyMarkup: markup)
    let spy = DeliverySpy(failRich: true)
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

  @Test
  func aTopicRowIsDeliveredIntoItsTopicAsAReply() async throws {
    // given — a row committed by a run in topic 5, answering message 88
    let groupChatID: Int64 = -1_001
    let seeded = try makeSeededFixture(
      chatID: groupChatID,
      sessionKey: SessionKey.telegramTopic(chatID: groupChatID, threadID: 5),
      telegramMessageID: 88
    )
    let fixture = Fixture(
      writer: seeded.writer,
      outbox: seeded.outbox,
      runID: seeded.runID,
      chatID: seeded.chatID
    )
    try seedPending(fixture, payload: "in the room")
    let spy = DeliverySpy()
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: spy,
      signal: OutboxSignal(),
      logger: TestLog.silent
    )

    // when
    await dispatcher.drainOnce()

    // then — the stamped target reached the delivery seam untouched
    #expect(
      await spy.targets == [
        DeliveryTarget(chatID: groupChatID, messageThreadID: 5, replyToMessageID: 88),
      ]
    )
  }

  @Test
  func aDirectRowIsDeliveredToItsChatAlone() async throws {
    // given
    let fixture = try makeFixture()
    try seedPending(fixture, payload: "hello")
    let spy = DeliverySpy()
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: spy,
      signal: OutboxSignal(),
      logger: TestLog.silent
    )

    // when
    await dispatcher.drainOnce()

    // then
    #expect(await spy.targets == [.chat(fixture.chatID)])
  }

  @Test
  func floodControlOnOneChatStillDrainsTheOtherChats() async throws {
    // given — two chats with a row each, and Telegram throttling the first
    let fixture = try makeTwoChatFixture(firstPayload: "throttled", secondPayload: "unaffected")
    let spy = DeliverySpy(outcomes: [
      fixture.firstChatID: .floodControl(retryAfter: 30, times: .max),
    ])
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: spy,
      signal: OutboxSignal(),
      logger: TestLog.silent,
      clock: ScriptedClock { _ in }
    )

    // when
    await dispatcher.drainOnce()

    // then — the throttled chat waits its turn out alone; the other chat's row went out
    #expect(await spy.deliveredPayloads == ["unaffected"])
    #expect(try fixture.outbox.pendingOutbound().map(\.payload) == ["throttled"])
  }

  @Test
  func aThrottledChatIsSkippedUntilItsRetryAfterHasPassed() async throws {
    // given — one chat, throttled on its first send only, and a clock whose retry wait is parked
    let hold = RetryWaitHold(retryAfter: .seconds(30))
    defer { hold.release() }
    let clock = hold.clock
    let fixture = try makeFixture()
    try seedPending(fixture, payload: "hello")
    let spy = DeliverySpy(outcomes: [fixture.chatID: .floodControl(retryAfter: 30, times: 1)])
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: spy,
      signal: OutboxSignal(),
      logger: TestLog.silent,
      clock: clock
    )

    // when — a second drain runs while the hold is still in force
    await dispatcher.drainOnce()
    await dispatcher.drainOnce()

    // then — it did not spend another request against the limit
    #expect(await spy.richAttempts == [fixture.chatID])
    #expect(try fixture.outbox.pendingOutbound().count == 1)

    // when — the retry window passes and the drain comes round again
    try await clock.sleep(for: .seconds(31))
    await dispatcher.drainOnce()

    // then — the held row delivers
    #expect(await spy.deliveredPayloads == ["hello"])
    #expect(try fixture.outbox.pendingOutbound().isEmpty)
  }

  @Test
  func floodControlOnTheRichSendIsNotRetriedAsPlainText() async throws {
    // given — a chat Telegram is throttling
    let fixture = try makeFixture()
    try seedPending(fixture, payload: "hello")
    let spy = DeliverySpy(outcomes: [fixture.chatID: .floodControl(retryAfter: 30, times: .max)])
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: spy,
      signal: OutboxSignal(),
      logger: TestLog.silent,
      clock: ScriptedClock { _ in }
    )

    // when
    await dispatcher.drainOnce()

    // then — one 429 cost one request, not two: the plain fallback answers formatting, not limits
    #expect(await spy.richAttempts == [fixture.chatID])
    #expect(await spy.plainAttempts.isEmpty)
  }

  @Test
  func floodControlSchedulesADrainOnceTheRetryWindowPasses() async throws {
    // given — nothing else will poke: the producer only pokes on a fresh commit
    let hold = RetryWaitHold(retryAfter: .seconds(30))
    defer { hold.release() }
    let fixture = try makeFixture()
    try seedPending(fixture, payload: "hello")
    let spy = DeliverySpy(outcomes: [fixture.chatID: .floodControl(retryAfter: 30, times: .max)])
    let signal = OutboxSignal()
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: spy,
      signal: signal,
      logger: TestLog.silent,
      clock: hold.clock
    )

    // when
    await dispatcher.drainOnce()
    await hold.waitStarted.wait()

    // then — it waits exactly the window Telegram named, then wakes the dispatcher up again
    #expect(hold.requestedDelays == [.seconds(30)])
    hold.release()
    for await _ in signal.notifications {
      break
    }
  }

  @Test
  func aNonFloodControlFailureStillStopsTheWholeDrain() async throws {
    // given — the first chat is undeliverable for a reason Telegram gave no retry window for
    let fixture = try makeTwoChatFixture(firstPayload: "stuck", secondPayload: "behind it")
    let spy = DeliverySpy(outcomes: [fixture.firstChatID: .unreachable])
    let dispatcher = OutboxDispatcher(
      outbox: fixture.outbox,
      delivery: spy,
      signal: OutboxSignal(),
      logger: TestLog.silent,
      clock: ScriptedClock { _ in }
    )

    // when
    await dispatcher.drainOnce()

    // then — unchanged stall-and-wait: the drain stops and every later row stays PENDING
    #expect(await spy.deliveredPayloads.isEmpty)
    #expect(try fixture.outbox.pendingOutbound().map(\.payload) == ["stuck", "behind it"])
  }
}
