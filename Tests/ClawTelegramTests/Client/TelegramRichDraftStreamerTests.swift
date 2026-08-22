import ClawCore
import ClawTelegram
import Foundation
import Testing

actor DraftTransport: TelegramTransport {
  struct DraftRecord: Sendable, Equatable {
    let chatId: Int64
    let draftId: Int64
    let markdown: String
  }

  private(set) var drafts: [DraftRecord] = []
  private(set) var draftAttempts: [DraftRecord] = []
  var throwDraft = false

  func getMe() async throws -> BotIdentity { BotIdentity(id: 1, username: "claw_bot") }

  func getUpdates(
    offset: Int64?,
    timeout: Int,
    allowedUpdates: [String]
  ) async throws -> [RawUpdate] { [] }

  func sendMessage(
    to target: DeliveryTarget,
    text: String,
    replyMarkup: String?
  ) async throws -> Int64 { 1 }

  func sendRichMessage(
    to target: DeliveryTarget,
    markdown: String,
    replyMarkup: String?
  ) async throws -> Int64 { 1 }

  func sendRichMessageDraft(chatId: Int64, draftId: Int64, markdown: String) async throws -> Bool {
    let record = DraftRecord(chatId: chatId, draftId: draftId, markdown: markdown)
    draftAttempts.append(record)
    if throwDraft {
      throw TelegramError.transport("draft down")
    }
    drafts.append(record)
    return true
  }

  func sendChatAction(chatId: Int64, action: String) async throws {}
}

@Suite struct TelegramRichDraftStreamerTests {
  @Test func capsDraftMarkdownAtRichMessageLimit() async throws {
    // given
    let transport = DraftTransport()
    let streamer = TelegramRichDraftStreamer(transport: transport)
    let long = String(repeating: "x", count: TelegramRichDraftStreamer.maxMarkdownCharacters + 10)

    // when
    await streamer.sendDraft(chatId: 42, draftId: 9, markdown: long)

    // then
    let draft = try #require(await transport.drafts.first)
    #expect(draft.chatId == 42)
    #expect(draft.draftId == 9)
    #expect(draft.markdown.count == TelegramRichDraftStreamer.maxMarkdownCharacters)
  }

  @Test func skipsDraftsForNonPrivateChats() async {
    // given
    let transport = DraftTransport()
    let streamer = TelegramRichDraftStreamer(transport: transport)

    // when
    await streamer.sendDraft(chatId: -100_123, draftId: 9, markdown: "group draft")

    // then
    #expect(await transport.drafts.isEmpty)
  }

  @Test func sendErrorsAreSwallowedAfterAttemptingTheDraft() async throws {
    // given
    let transport = DraftTransport()
    await transport.setThrowDraft(true)
    let streamer = TelegramRichDraftStreamer(transport: transport)

    // when
    await streamer.sendDraft(chatId: 42, draftId: 9, markdown: "partial")

    // then
    let attempt = try #require(await transport.draftAttempts.first)
    #expect(attempt == DraftTransport.DraftRecord(chatId: 42, draftId: 9, markdown: "partial"))
    #expect(await transport.drafts.isEmpty)
  }
}

extension DraftTransport {
  func setThrowDraft(_ value: Bool) {
    throwDraft = value
  }
}
