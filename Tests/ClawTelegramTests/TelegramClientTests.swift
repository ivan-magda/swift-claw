import Foundation
import Testing

@testable import ClawCore
@testable import ClawTelegram

struct MockHTTPExecutor: HTTPExecuting {
  let result: HTTPResult

  func post(url: String, jsonBody: Data, timeoutSeconds: Int) async throws -> HTTPResult { result }
}

/// Simulates a transport error whose description echoes the request URL (which carries the token).
struct URLEchoingExecutor: HTTPExecuting {
  struct URLEchoError: Error, CustomStringConvertible {
    let url: String
    var description: String { "connection failed for \(url)" }
  }

  func post(url: String, jsonBody: Data, timeoutSeconds: Int) async throws -> HTTPResult {
    throw URLEchoError(url: url)
  }
}

private func client(status: Int, json: String) -> TelegramClient {
  TelegramClient(
    token: "T",
    http: MockHTTPExecutor(result: HTTPResult(statusCode: status, body: Data(json.utf8))),
    baseURL: "https://example.test")
}

@Suite struct TelegramClientTests {
  @Test func decodesGetMe() async throws {
    // given
    let telegram = client(
      status: 200,
      json: #"{"ok":true,"result":{"id":555,"is_bot":true,"username":"claw_bot"}}"#
    )

    // when
    let identity = try await telegram.getMe()

    // then
    #expect(identity.id == 555)
    #expect(identity.username == "claw_bot")
  }

  @Test func decodesTextUpdate() async throws {
    // given
    let telegram = client(
      status: 200,
      json: #"""
        {"ok":true,"result":[
          {"update_id":12,"message":{"message_id":3,"from":{"id":42},"chat":{"id":42},"text":"hi"}}
        ]}
        """#
    )

    // when
    let updates =
      try await telegram.getUpdates(offset: nil, timeout: 0, allowedUpdates: ["message"])

    // then
    #expect(updates.count == 1)
    #expect(updates[0].updateId == 12)
    #expect(updates[0].message?.text == "hi")
    #expect(updates[0].message?.fromUserId == 42)
  }

  @Test func mapsMediaToFriendlyKind() async throws {
    // given
    let telegram = client(
      status: 200,
      json: #"""
        {"ok":true,"result":[
          {"update_id":13,"message":{"message_id":4,"from":{"id":42},"chat":{"id":42},"voice":{}}}
        ]}
        """#
    )

    // when
    let updates =
      try await telegram.getUpdates(offset: nil, timeout: 0, allowedUpdates: ["message"])

    // then
    #expect(updates[0].message?.mediaKind == "voice messages")
    #expect(updates[0].message?.text == nil)
  }

  @Test func maps409ToConflict() async throws {
    // given
    let telegram = client(
      status: 409,
      json:
        #"{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}"#
    )

    // then
    await #expect(
      throws: TelegramError.conflict409(
        description: "Conflict: terminated by other getUpdates request"
      )
    ) {
      _ = try await telegram.getMe()
    }
  }

  @Test func maps429ToFloodControlWithRetryAfter() async throws {
    // given
    let telegram = client(
      status: 429,
      json:
        #"{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":7}}"#
    )

    // then
    await #expect(throws: TelegramError.floodControl(retryAfter: 7)) {
      _ = try await telegram.getMe()
    }
  }

  @Test func mapsOtherApiErrors() async throws {
    // given
    let telegram = client(
      status: 400, json: #"{"ok":false,"error_code":400,"description":"Bad Request"}"#
    )

    // then
    await #expect(throws: TelegramError.apiError(code: 400, description: "Bad Request")) {
      _ = try await telegram.getMe()
    }
  }

  @Test func malformedBodyIsDecodingError() async throws {
    // given
    let telegram = client(status: 200, json: "not json")

    // then
    await #expect(throws: TelegramError.self) { _ = try await telegram.getMe() }
  }

  @Test func transportErrorRedactsTheBotToken() async throws {
    // given: the token is in the request URL; a transport error echoing the URL must NOT leak it
    let telegram = TelegramClient(
      token: "SECRET-123:abc", http: URLEchoingExecutor(), baseURL: "https://example.test"
    )

    // then
    do {
      _ = try await telegram.getMe()
      Issue.record("expected a transport error")
    } catch let TelegramError.transport(message) {
      #expect(message.contains("SECRET-123:abc") == false)
      #expect(message.contains("<redacted-token>"))
    }
  }
}
