import Foundation
import Testing

@testable import ClawCore
@testable import ClawTelegram

/// Captures the posted JSON body so the test can assert the exact wire shape sent to Telegram,
/// then returns a canned `sendRichMessage` success envelope.
private actor CapturingExecutor: HTTPExecuting {
  private(set) var capturedBody: Data?
  private let result: HTTPResult

  init(result: HTTPResult) { self.result = result }

  func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult {
    capturedBody = jsonBody
    return result
  }
}

@Suite struct RichMessageTests {
  @Test func sendRichMessagePostsMarkdownInputRichMessage() async throws {
    // given — a transport whose executor records the request body and returns message_id 99
    let executor = CapturingExecutor(
      result: HTTPResult(
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
    let body = try #require(await executor.capturedBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let richMessage = try #require(json["rich_message"] as? [String: Any])
    #expect(richMessage["markdown"] as? String == "**hi**")
  }
}
