import ClawCore
import ClawTestSupport
import Testing

@testable import ClawTelegram

@Suite
struct TelegramDraftEmojiFallbackTests {
  @Test
  func emojiRejectionRetriesOnlyHeadingAndRemembersSuccessfulFallback() async {
    // given
    let transport = DraftTransport()
    await transport.rejectDrafts([.apiError(code: 400, description: "Unsupported emoji")])
    let streamer = TelegramRichDraftStreamer(transport: transport)
    let answer = "\n\nAnswer \(TelegramActionEmoji.answer.markup)"
    let draft = RichDraft(markdown: decorated + answer, fallbackMarkdown: ordinary + answer)

    // when
    let delivered = await streamer.sendDraft(
      chatID: 42,
      draftID: 9,
      draft: draft,
      stopControl: .unavailable
    )
    let next = await streamer.sendDraft(
      chatID: 42,
      draftID: 10,
      draft: draft,
      stopControl: .unavailable
    )
    let answerOnly = await streamer.sendDraft(chatID: 42, draftID: 11, markdown: decorated)

    // then
    #expect(delivered)
    #expect(next)
    #expect(answerOnly)
    let attempts = await transport.draftAttempts
    #expect(
      attempts.map(\.markdown)
        == [draft.markdown, ordinary + answer, ordinary + answer, decorated]
    )
    #expect(attempts.allSatisfy { $0.chatID == 42 })
    #expect(attempts.map(\.draftID) == [9, 9, 10, 11])
  }

  @Test(arguments: [
    TelegramError.apiError(code: 400, description: "Invalid draft"),
    TelegramError.transport("unavailable"),
  ])
  func unsuccessfulFallbackDoesNotDisableCustomEmoji(_ error: TelegramError) async {
    // given
    let transport = DraftTransport()
    await transport.rejectDrafts([.apiError(code: 400, description: "Rejected"), error])
    let streamer = TelegramRichDraftStreamer(transport: transport)

    // when
    let first = await streamer.sendDraft(
      chatID: 42,
      draftID: 9,
      draft: frame,
      stopControl: .unavailable
    )
    let next = await streamer.sendDraft(
      chatID: 42,
      draftID: 9,
      draft: frame,
      stopControl: .unavailable
    )

    // then
    #expect(first == false)
    #expect(next)
    #expect(await transport.draftAttempts.map(\.markdown) == [decorated, ordinary, decorated])
  }

  @Test
  func floodControlOnFallbackHoldsTheChatAndRetainsCustomEmoji() async throws {
    // given
    let transport = DraftTransport()
    await transport.rejectDrafts([
      .apiError(code: 400, description: "Rejected"),
      .floodControl(retryAfter: 5),
    ])
    let clock = ScriptedClock { _ in
      await Task.yield()
    }
    let streamer = TelegramRichDraftStreamer(transport: transport, clock: clock)

    // when
    let first = await streamer.sendDraft(
      chatID: 42,
      draftID: 9,
      draft: frame,
      stopControl: .unavailable
    )
    let held = await streamer.sendDraft(
      chatID: 42,
      draftID: 9,
      draft: frame,
      stopControl: .unavailable
    )
    try await clock.sleep(for: .seconds(5))
    let resumed = await streamer.sendDraft(
      chatID: 42,
      draftID: 9,
      draft: frame,
      stopControl: .unavailable
    )

    // then
    #expect(first == false)
    #expect(held == false)
    #expect(resumed)
    #expect(await transport.draftAttempts.map(\.markdown) == [decorated, ordinary, decorated])
  }

  @Test(arguments: [
    (TelegramError.apiError(code: 500, description: "Unavailable"), true),
    (.apiError(code: 400, description: "Bad"), false),
  ])
  func retryRequiresBadRequestAndAnOwnedHeading(
    error: TelegramError,
    hasFallback: Bool
  ) async {
    // given
    let draft = RichDraft(markdown: decorated, fallbackMarkdown: hasFallback ? ordinary : nil)
    let transport = DraftTransport()
    await transport.rejectDrafts([error])
    let streamer = TelegramRichDraftStreamer(transport: transport)

    // when
    let delivered = await streamer.sendDraft(
      chatID: 42,
      draftID: 9,
      draft: draft,
      stopControl: .unavailable
    )

    // then
    #expect(delivered == false)
    #expect(await transport.draftAttempts.map(\.markdown) == [draft.markdown])
  }

  @Test
  func cancellationAfterRejectionPreventsFallbackSend() async {
    // given
    let transport = DraftTransport()
    await transport.rejectDrafts(
      [.apiError(code: 400, description: "Rejected")],
      cancelling: true
    )
    let streamer = TelegramRichDraftStreamer(transport: transport)

    // when
    let send = Task {
      await streamer.sendDraft(chatID: 42, draftID: 9, draft: frame, stopControl: .unavailable)
    }
    let delivered = await send.value

    // then
    #expect(delivered == false)
    #expect(await transport.draftAttempts.map(\.markdown) == [decorated])
  }
}

// MARK: - Fixtures

private extension TelegramDraftEmojiFallbackTests {
  var frame: RichDraft {
    RichDraft(markdown: decorated, fallbackMarkdown: ordinary)
  }

  var decorated: String {
    "<tg-thinking>\(TelegramActionEmoji.thinking.markup) Working</tg-thinking>"
  }

  var ordinary: String {
    "<tg-thinking>\(TelegramActionEmoji.thinking.fallback) Working</tg-thinking>"
  }
}
