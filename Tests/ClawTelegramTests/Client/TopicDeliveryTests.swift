import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore
@testable import ClawTelegram

@Suite
struct TopicDeliveryTests {
  private func makeClient(_ executor: RecordingHTTPExecutor) -> TelegramClient {
    TelegramClient(token: "T", http: executor, baseURL: "https://example.test")
  }

  private func makeExecutor() -> RecordingHTTPExecutor {
    RecordingHTTPExecutor(
      cannedResult: HTTPResult(
        statusCode: 200,
        headers: [:],
        body: Data(#"{"ok":true,"result":{"message_id":7,"chat":{"id":-1001}}}"#.utf8)
      )
    )
  }

  private func body(
    _ executor: RecordingHTTPExecutor
  ) async throws -> [String: Any] {
    let raw = try #require(await executor.lastBody)
    return try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
  }

  /// `allow_sending_without_reply` matters: without it a deleted target answers 400, which stalls
  /// the row and every later one behind it on every drain — one removed message would wedge
  /// delivery for every topic. The reply then degrades to a plain in-topic message.
  @Test
  func plainSendCarriesTheTopicAndAReplyTargetThatMayBeGone() async throws {
    // given
    let executor = makeExecutor()
    let target = DeliveryTarget(chatID: -1_001, messageThreadID: 5, replyToMessageID: 88)

    // when
    _ = try await makeClient(executor).sendMessage(to: target, text: "answer", replyMarkup: nil)

    // then — the topic rides the request, and Telegram is told to send even without the target
    let json = try await body(executor)
    #expect(json["message_thread_id"] as? Int64 == 5)
    let replyParameters = try #require(json["reply_parameters"] as? [String: Any])
    #expect(replyParameters["message_id"] as? Int64 == 88)
    #expect(replyParameters["allow_sending_without_reply"] as? Bool == true)
  }

  @Test
  func richSendCarriesTheTopicAndTheReplyTarget() async throws {
    // given
    let executor = makeExecutor()
    let target = DeliveryTarget(chatID: -1_001, messageThreadID: 5, replyToMessageID: 88)

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

  @Test
  func aGeneralTopicSendCarriesAReplyTargetButNoThread() async throws {
    // given — the General topic has no `message_thread_id` to carry
    let executor = makeExecutor()
    let target = DeliveryTarget(chatID: -1_001, messageThreadID: nil, replyToMessageID: 88)

    // when
    _ = try await makeClient(executor).sendMessage(to: target, text: "answer", replyMarkup: nil)

    // then
    let json = try await body(executor)
    #expect(json["message_thread_id"] == nil)
    #expect(json["reply_parameters"] != nil)
  }

  @Test
  func aDirectSendCarriesNeitherTopicNorReply() async throws {
    // given
    let executor = makeExecutor()

    // when
    _ = try await makeClient(executor).sendMessage(chatID: 42, text: "answer")

    // then — the DM request is exactly what it was before topics existed
    let json = try await body(executor)
    #expect(json["message_thread_id"] == nil)
    #expect(json["reply_parameters"] == nil)
    #expect(json["chat_id"] as? Int64 == 42)
  }

  @Test
  func aTypingActionCarriesTheTopic() async throws {
    // given
    let executor = makeExecutor()
    let indicator = TelegramTypingIndicator(transport: makeClient(executor))

    // when
    await indicator.sendTyping(chatID: -1_001, messageThreadID: 5)

    // then
    let json = try await body(executor)
    #expect(json["message_thread_id"] as? Int64 == 5)
    #expect(json["action"] as? String == "typing")
  }

  @Test
  func aDirectTypingActionCarriesNoTopic() async throws {
    // given
    let executor = makeExecutor()
    let indicator = TelegramTypingIndicator(transport: makeClient(executor))

    // when
    await indicator.sendTyping(chatID: 42)

    // then — the DM request is exactly what it was before topics existed
    let json = try await body(executor)
    #expect(json["message_thread_id"] == nil)
    #expect(json["chat_id"] as? Int64 == 42)
  }
}
