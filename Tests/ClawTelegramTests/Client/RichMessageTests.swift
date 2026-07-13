import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore
@testable import ClawTelegram

@Suite struct RichMessageTests {
  @Test func sendRichMessagePostsMarkdownInputRichMessage() async throws {
    // given — a transport whose executor records the request body and returns message_id 99
    let executor = ClawTestSupport.RecordingHTTPExecutor(
      cannedResult: HTTPResult(
        statusCode: 200,
        headers: [:],
        body: Data(#"{"ok":true,"result":{"message_id":99,"chat":{"id":42}}}"#.utf8)
      )
    )
    let telegram = TelegramClient(token: "T", http: executor, baseURL: "https://example.test")

    // when
    let messageId = try await telegram.sendRichMessage(chatId: 42, markdown: "**hi**")

    // then — the assigned id comes back, and the markdown rode inside `rich_message` verbatim
    #expect(messageId == 99)
    let body = try #require(await executor.lastBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let richMessage = try #require(json["rich_message"] as? [String: Any])
    #expect(richMessage["markdown"] as? String == "**hi**")

    // then — link previews are disabled unconditionally (ARCHITECTURE §12)
    let linkPreviewOptions = try #require(json["link_preview_options"] as? [String: Any])
    #expect(linkPreviewOptions["is_disabled"] as? Bool == true)
  }
}
