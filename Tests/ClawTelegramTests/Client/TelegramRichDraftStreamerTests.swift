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
  var hangDraft = false
  var throwDraft = false

  func getMe() async throws -> BotIdentity { BotIdentity(id: 1, username: "claw_bot") }

  func getUpdates(
    offset: Int64?,
    timeout: Int,
    allowedUpdates: [String]
  ) async throws -> [RawUpdate] { [] }

  func sendMessage(chatId: Int64, text: String) async throws -> Int64 { 1 }

  func sendRichMessage(chatId: Int64, markdown: String) async throws -> Int64 { 1 }

  func sendRichMessageDraft(chatId: Int64, draftId: Int64, markdown: String) async throws -> Bool {
    if hangDraft {
      try await Task.sleep(for: .seconds(3_600))
    }
    if throwDraft {
      throw TelegramError.transport("draft down")
    }
    drafts.append(DraftRecord(chatId: chatId, draftId: draftId, markdown: markdown))
    return true
  }

  func sendChatAction(chatId: Int64, action: String) async throws {}
}

@Suite struct TelegramRichDraftStreamerTests {
  @Test func capsDraftMarkdownAtRichMessageLimit() async throws {
    // given
    let transport = DraftTransport()
    let streamer = TelegramRichDraftStreamer(
      transport: transport,
      sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
    )
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
    let streamer = TelegramRichDraftStreamer(transport: transport, sleep: { _ in })

    // when
    await streamer.sendDraft(chatId: -100_123, draftId: 9, markdown: "group draft")

    // then
    #expect(await transport.drafts.isEmpty)
  }

  @Test func sendErrorsAreSwallowed() async {
    // given
    let transport = DraftTransport()
    await transport.setThrowDraft(true)
    let streamer = TelegramRichDraftStreamer(transport: transport, sleep: { _ in })

    // when
    await streamer.sendDraft(chatId: 42, draftId: 9, markdown: "partial")

    // then
    #expect(await transport.drafts.isEmpty)
  }

  @Test func deadlinePreventsHungTransportFromBlockingCaller() async {
    // given
    let transport = DraftTransport()
    await transport.setHangDraft(true)
    let streamer = TelegramRichDraftStreamer(transport: transport, sleep: { _ in })

    // when
    await streamer.sendDraft(chatId: 42, draftId: 9, markdown: "partial")

    // then
    #expect(await transport.drafts.isEmpty)
  }
}

extension DraftTransport {
  func setHangDraft(_ value: Bool) {
    hangDraft = value
  }

  func setThrowDraft(_ value: Bool) {
    throwDraft = value
  }
}
