import ClawCore
import ClawTelegram
import ClawTestSupport
import Foundation
import Testing

actor DraftTransport: TelegramTransport {
  struct DraftRecord: Sendable, Equatable {
    let chatID: Int64
    let draftID: Int64
    let markdown: String
  }

  private(set) var drafts: [DraftRecord] = []
  private(set) var draftAttempts: [DraftRecord] = []
  var throwDraft = false
  /// One-shot: the next attempt is answered with flood control carrying this `retry_after`.
  var floodControlRetryAfter: Int?
  private var draftErrors: [TelegramError] = []
  private var cancelBeforeError = false

  func getMe() async throws -> BotIdentity {
    BotIdentity(id: 1, username: "claw_bot")
  }

  func getUpdates(
    offset: Int64?,
    timeout: Int,
    allowedUpdates: [String]
  ) async throws -> [RawUpdate] {
    []
  }

  func sendMessage(
    to target: DeliveryTarget,
    text: String,
    replyMarkup: String?
  ) async throws -> Int64 {
    1
  }

  func sendRichMessage(
    to target: DeliveryTarget,
    markdown: String,
    replyMarkup: String?
  ) async throws -> Int64 {
    1
  }

  func sendRichMessageDraft(chatID: Int64, draftID: Int64, markdown: String) async throws -> Bool {
    let record = DraftRecord(chatID: chatID, draftID: draftID, markdown: markdown)
    draftAttempts.append(record)
    if !draftErrors.isEmpty {
      if cancelBeforeError {
        withUnsafeCurrentTask { task in
          task?.cancel()
        }
      }
      throw draftErrors.removeFirst()
    }
    if let retryAfter = floodControlRetryAfter {
      floodControlRetryAfter = nil
      throw TelegramError.floodControl(retryAfter: retryAfter)
    }
    if throwDraft {
      throw TelegramError.transport("draft down")
    }
    drafts.append(record)
    return true
  }

  func sendChatAction(chatID: Int64, messageThreadID: Int64?, action: String) async throws {}
}

@Suite
struct TelegramRichDraftStreamerTests {
  @Test
  func capsDraftMarkdownAtRichMessageLimit() async throws {
    // given
    let transport = DraftTransport()
    let streamer = TelegramRichDraftStreamer(transport: transport)
    let long = String(repeating: "x", count: TelegramMessageLimits.maxRichMessageCharacters + 10)

    // when
    let delivered = await streamer.sendDraft(chatID: 42, draftID: 9, markdown: long)

    // then
    #expect(delivered)
    let draft = try #require(await transport.drafts.first)
    #expect(draft.chatID == 42)
    #expect(draft.draftID == 9)
    #expect(draft.markdown.count == TelegramMessageLimits.maxRichMessageCharacters)
  }

  /// Telegram accepts a draft only in a private chat, so a group draft is dropped rather than sent
  /// to the supergroup — and reported as undelivered, which is what keeps the caller's typing pulse
  /// alive in a topic that will never show a bubble.
  @Test
  func reportsNoDeliveryForNonPrivateChats() async {
    // given
    let transport = DraftTransport()
    let streamer = TelegramRichDraftStreamer(transport: transport)

    // when
    let delivered = await streamer.sendDraft(chatID: -100_123, draftID: 9, markdown: "group draft")

    // then
    #expect(delivered == false)
    #expect(await transport.draftAttempts.isEmpty)
    #expect(await transport.drafts.isEmpty)
  }

  @Test
  func sendErrorsAreSwallowedAfterAttemptingTheDraft() async throws {
    // given
    let transport = DraftTransport()
    await transport.setThrowDraft(true)
    let streamer = TelegramRichDraftStreamer(transport: transport)

    // when
    let delivered = await streamer.sendDraft(chatID: 42, draftID: 9, markdown: "partial")

    // then
    #expect(delivered == false)
    let attempt = try #require(await transport.draftAttempts.first)
    #expect(attempt == DraftTransport.DraftRecord(chatID: 42, draftID: 9, markdown: "partial"))
    #expect(await transport.drafts.isEmpty)
  }

  /// The probe loop offers a frame every tick; a chat Telegram throttled must see none of them
  /// until the `retry_after` it named has passed, and drafts must resume after that.
  @Test
  func floodControlHoldsTheChatsDraftsUntilRetryAfterPasses() async throws {
    // given
    let transport = DraftTransport()
    await transport.failNextDraft(withFloodControlRetryAfter: 5)
    let clock = ScriptedClock { _ in
      await Task.yield()
    }
    let streamer = TelegramRichDraftStreamer(transport: transport, clock: clock)
    _ = await streamer.sendDraft(chatID: 42, draftID: 9, markdown: "throttled")

    // when
    let duringHold = await streamer.sendDraft(chatID: 42, draftID: 9, markdown: "held")
    try await clock.sleep(for: .seconds(5))
    let afterHold = await streamer.sendDraft(chatID: 42, draftID: 9, markdown: "resumed")

    // then
    #expect(duringHold == false)
    #expect(afterHold)
    #expect(await transport.draftAttempts.map(\.markdown) == ["throttled", "resumed"])
  }
}

extension DraftTransport {
  func rejectDrafts(_ errors: [TelegramError], cancelling: Bool = false) {
    draftErrors = errors
    cancelBeforeError = cancelling
  }

  func setThrowDraft(_ value: Bool) {
    throwDraft = value
  }

  func failNextDraft(withFloodControlRetryAfter retryAfter: Int) {
    floodControlRetryAfter = retryAfter
  }
}
