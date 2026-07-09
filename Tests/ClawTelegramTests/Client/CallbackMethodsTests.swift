import Foundation
import Testing

@testable import ClawCore
@testable import ClawTelegram

@Suite struct CallbackMethodsTests {
  private static let okBool = HTTPResult(
    statusCode: 200,
    headers: [:],
    body: Data(#"{"ok":true,"result":true}"#.utf8)
  )

  private func makeClient(
    result: HTTPResult
  ) -> (client: TelegramClient, recorder: RecordingHTTPExecutor.Recorder) {
    let recorder = RecordingHTTPExecutor.Recorder()
    let executor = RecordingHTTPExecutor(recorder: recorder, result: result)
    let client = TelegramClient(token: "T", http: executor, baseURL: "https://example.test")
    return (client, recorder)
  }

  private func bodyObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func answerCallbackQueryPostsTheCallbackId() async throws {
    // given
    let harness = makeClient(result: Self.okBool)

    // when — the spinner-stopping answer carries callback_query_id + the neutral toast text
    try await harness.client.answerCallbackQuery(id: "cbq-1", text: "already handled")

    // then
    let call = try #require(await harness.recorder.calls.first)
    #expect(call.url.hasSuffix("/answerCallbackQuery"))
    let body = try bodyObject(call.body)
    #expect(body["callback_query_id"] as? String == "cbq-1")
    #expect(body["text"] as? String == "already handled")
  }

  @Test func answerCallbackQueryOmitsAbsentText() async throws {
    // given
    let harness = makeClient(result: Self.okBool)

    // when
    try await harness.client.answerCallbackQuery(id: "cbq-2", text: nil)

    // then — a nil toast is omitted, not sent as JSON null
    let body = try bodyObject(try #require(await harness.recorder.calls.first).body)
    #expect(body["callback_query_id"] as? String == "cbq-2")
    #expect(body["text"] == nil)
  }

  @Test func editMessageReplyMarkupSendsTheKeyboardObject() async throws {
    // given
    let harness = makeClient(result: Self.okBool)
    let markup = #"{"inline_keyboard":[[{"text":"Approve","callback_data":"apr:abc:y"}]]}"#

    // when
    try await harness.client.editMessageReplyMarkup(chatId: 7, messageId: 500, replyMarkup: markup)

    // then — reply_markup rides as a JSON OBJECT (decoded from the string), never a string
    let call = try #require(await harness.recorder.calls.first)
    #expect(call.url.hasSuffix("/editMessageReplyMarkup"))
    let body = try bodyObject(call.body)
    #expect(body["chat_id"] as? Int == 7)
    #expect(body["message_id"] as? Int == 500)
    let replyMarkup = try #require(body["reply_markup"] as? [String: Any])
    let rows = try #require(replyMarkup["inline_keyboard"] as? [[[String: String]]])
    #expect(rows[0][0]["callback_data"] == "apr:abc:y")
  }

  @Test func editMessageReplyMarkupWithNilRemovesTheKeyboard() async throws {
    // given
    let harness = makeClient(result: Self.okBool)

    // when — button disarm: nil markup omits reply_markup, telling Telegram to drop the keyboard
    try await harness.client.editMessageReplyMarkup(chatId: 7, messageId: 500, replyMarkup: nil)

    // then
    let body = try bodyObject(try #require(await harness.recorder.calls.first).body)
    #expect(body["reply_markup"] == nil)
  }

  @Test func sendMessageWithReplyMarkupCarriesTheKeyboard() async throws {
    // given
    let harness = makeClient(
      result: HTTPResult(
        statusCode: 200,
        headers: [:],
        body: Data(#"{"ok":true,"result":{"message_id":123,"chat":{"id":7}}}"#.utf8)
      )
    )
    let markup = #"{"inline_keyboard":[[{"text":"Approve","callback_data":"apr:abc:y"}]]}"#

    // when
    let messageId = try await harness.client.sendMessage(
      chatId: 7,
      text: "approve?",
      replyMarkup: markup
    )

    // then
    #expect(messageId == 123)
    let body = try bodyObject(try #require(await harness.recorder.calls.first).body)
    let replyMarkup = try #require(body["reply_markup"] as? [String: Any])
    #expect(replyMarkup["inline_keyboard"] != nil)
  }

  @Test func plainSendMessageOmitsReplyMarkup() async throws {
    // given
    let harness = makeClient(
      result: HTTPResult(
        statusCode: 200,
        headers: [:],
        body: Data(#"{"ok":true,"result":{"message_id":1,"chat":{"id":7}}}"#.utf8)
      )
    )

    // when — the two-arg MessageDelivery path used by ordinary replies (unchanged behavior)
    _ = try await harness.client.sendMessage(chatId: 7, text: "hi")

    // then — no keyboard key leaks onto non-approval replies
    let body = try bodyObject(try #require(await harness.recorder.calls.first).body)
    #expect(body["reply_markup"] == nil)
    #expect(body["text"] as? String == "hi")
  }
}
