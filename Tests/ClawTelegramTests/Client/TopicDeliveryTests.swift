import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore
@testable import ClawTelegram

@Suite struct TopicDeliveryTests {
  private func makeClient(
    _ executor: ClawTestSupport.RecordingHTTPExecutor
  ) -> TelegramClient {
    TelegramClient(token: "T", http: executor, baseURL: "https://example.test")
  }

  private func makeExecutor() -> ClawTestSupport.RecordingHTTPExecutor {
    ClawTestSupport.RecordingHTTPExecutor(
      cannedResult: HTTPResult(
        statusCode: 200,
        headers: [:],
        body: Data(#"{"ok":true,"result":{"message_id":7,"chat":{"id":-1001}}}"#.utf8)
      )
    )
  }

  private func body(
    _ executor: ClawTestSupport.RecordingHTTPExecutor
  ) async throws -> [String: Any] {
    let raw = try #require(await executor.lastBody)
    return try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
  }

  @Test func plainSendCarriesTheTopicAndTheReplyTarget() async throws {
    // given
    let executor = makeExecutor()
    let target = DeliveryTarget(chatId: -1_001, messageThreadId: 5, replyToMessageId: 88)

    // when
    _ = try await makeClient(executor).sendMessage(to: target, text: "answer", replyMarkup: nil)

    // then
    let json = try await body(executor)
    #expect(json["message_thread_id"] as? Int64 == 5)
    let replyParameters = try #require(json["reply_parameters"] as? [String: Any])
    #expect(replyParameters["message_id"] as? Int64 == 88)
  }

  @Test func richSendCarriesTheTopicAndTheReplyTarget() async throws {
    // given
    let executor = makeExecutor()
    let target = DeliveryTarget(chatId: -1_001, messageThreadId: 5, replyToMessageId: 88)

    // when
    _ = try await makeClient(executor).sendRichMessage(
      to: target,
      markdown: "**answer**",
      replyMarkup: nil
    )

    // then
    let json = try await body(executor)
    #expect(json["message_thread_id"] as? Int64 == 5)
    let replyParameters = try #require(json["reply_parameters"] as? [String: Any])
    #expect(replyParameters["message_id"] as? Int64 == 88)
  }

  /// Without the flag a deleted target answers 400, which stalls the row and every later one
  /// behind it on every drain — one removed message would wedge delivery for every topic.
  @Test func aReplyDegradesToAPlainInTopicMessageWhenItsTargetIsGone() async throws {
    // given
    let executor = makeExecutor()
    let target = DeliveryTarget(chatId: -1_001, messageThreadId: 5, replyToMessageId: 88)

    // when
    _ = try await makeClient(executor).sendMessage(to: target, text: "answer", replyMarkup: nil)

    // then — the topic still rides the request, and Telegram is told to send anyway
    let json = try await body(executor)
    let replyParameters = try #require(json["reply_parameters"] as? [String: Any])
    #expect(replyParameters["allow_sending_without_reply"] as? Bool == true)
    #expect(json["message_thread_id"] as? Int64 == 5)
  }

  @Test func aGeneralTopicSendCarriesAReplyTargetButNoThread() async throws {
    // given — the General topic has no `message_thread_id` to carry
    let executor = makeExecutor()
    let target = DeliveryTarget(chatId: -1_001, messageThreadId: nil, replyToMessageId: 88)

    // when
    _ = try await makeClient(executor).sendMessage(to: target, text: "answer", replyMarkup: nil)

    // then
    let json = try await body(executor)
    #expect(json["message_thread_id"] == nil)
    #expect(json["reply_parameters"] != nil)
  }

  @Test func aDirectSendCarriesNeitherTopicNorReply() async throws {
    // given
    let executor = makeExecutor()

    // when
    _ = try await makeClient(executor).sendMessage(chatId: 42, text: "answer")

    // then — the DM request is exactly what it was before topics existed
    let json = try await body(executor)
    #expect(json["message_thread_id"] == nil)
    #expect(json["reply_parameters"] == nil)
    #expect(json["chat_id"] as? Int64 == 42)
  }
}
