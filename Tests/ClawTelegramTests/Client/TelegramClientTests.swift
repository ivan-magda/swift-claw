import Foundation
import Testing

@testable import ClawCore
@testable import ClawTelegram

struct MockHTTPExecutor: HTTPExecuting {
  let result: HTTPResult

  func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult { result }

  func get(
    url: String,
    headers: [String: String],
    timeoutSeconds: Int,
    maxBodyBytes: Int
  ) async throws -> HTTPResult {
    struct GetUnsupported: Error {}
    throw GetUnsupported()
  }
}

struct RecordingHTTPExecutor: HTTPExecuting {
  struct Call: Sendable {
    let url: String
    let body: Data
    let timeout: Int
  }

  actor Recorder {
    private(set) var calls: [Call] = []

    func append(url: String, body: Data, timeout: Int) {
      calls.append(Call(url: url, body: body, timeout: timeout))
    }
  }

  let recorder: Recorder
  let result: HTTPResult

  func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult {
    await recorder.append(url: url, body: jsonBody, timeout: timeoutSeconds)
    return result
  }

  func get(
    url: String,
    headers: [String: String],
    timeoutSeconds: Int,
    maxBodyBytes: Int
  ) async throws -> HTTPResult {
    struct GetUnsupported: Error {}
    throw GetUnsupported()
  }
}

/// Simulates a transport error whose description echoes the request URL (which carries the token).
struct URLEchoingExecutor: HTTPExecuting {
  struct URLEchoError: Error, CustomStringConvertible {
    let url: String
    var description: String { "connection failed for \(url)" }
  }

  func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult {
    throw URLEchoError(url: url)
  }

  func get(
    url: String,
    headers: [String: String],
    timeoutSeconds: Int,
    maxBodyBytes: Int
  ) async throws -> HTTPResult {
    struct GetUnsupported: Error {}
    throw GetUnsupported()
  }
}

private func client(status: Int, json: String) -> TelegramClient {
  TelegramClient(
    token: "T",
    http: MockHTTPExecutor(
      result: HTTPResult(statusCode: status, headers: [:], body: Data(json.utf8))
    ),
    baseURL: "https://example.test"
  )
}

@Suite struct TelegramClientTests {
  struct HTTPErrorCase: Sendable {
    let status: Int
    let json: String
    let expected: TelegramError
  }

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
    let update = try #require(updates.first)
    #expect(update.updateId == 12)
    #expect(update.message?.text == "hi")
    #expect(update.message?.fromUserId == 42)
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
    let update = try #require(updates.first)
    #expect(update.message?.mediaKind == "voice messages")
    #expect(update.message?.text == nil)
  }

  @Test(
    arguments: [
      HTTPErrorCase(
        status: 409,
        json:
          #"{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}"#,
        expected: TelegramError.conflict409(
          description: "Conflict: terminated by other getUpdates request"
        )
      ),
      HTTPErrorCase(
        status: 429,
        json:
          #"{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":7}}"#,
        expected: TelegramError.floodControl(retryAfter: 7)
      ),
      HTTPErrorCase(
        status: 400,
        json: #"{"ok":false,"error_code":400,"description":"Bad Request"}"#,
        expected: TelegramError.apiError(code: 400, description: "Bad Request")
      ),
    ]
  )
  func mapsHttpStatusToTelegramError(_ errorCase: HTTPErrorCase) async throws {
    // given
    let telegram = client(status: errorCase.status, json: errorCase.json)

    // then
    await #expect(throws: errorCase.expected) {
      _ = try await telegram.getMe()
    }
  }

  @Test func malformedBodyIsDecodingError() async throws {
    // given
    let telegram = client(status: 200, json: "not json")

    // then
    await #expect {
      _ = try await telegram.getMe()
    } throws: { error in
      guard let telegramErr = error as? TelegramError else { return false }
      if case .decoding = telegramErr { return true }
      return false
    }
  }

  @Test func transportErrorRedactsTheBotToken() async throws {
    // given: the token is in the request URL; a transport error echoing the URL must NOT leak it
    let telegram = TelegramClient(
      token: "SECRET-123:abc",
      http: URLEchoingExecutor(),
      baseURL: "https://example.test"
    )

    // when
    var thrownMessage: String?
    await #expect {
      _ = try await telegram.getMe()
    } throws: { error in
      guard case TelegramError.transport(let message) = error else { return false }
      thrownMessage = message
      return true
    }

    // then
    let message = try #require(thrownMessage)
    #expect(message.contains("SECRET-123:abc") == false)
    #expect(message.contains("<redacted-token>"))
  }

  @Test func setMyCommandsPostsCorrectPayload() async throws {
    // given
    let recorder = RecordingHTTPExecutor.Recorder()
    let http = RecordingHTTPExecutor(
      recorder: recorder,
      result: HTTPResult(
        statusCode: 200,
        headers: [:],
        body: Data(#"{"ok":true,"result":true}"#.utf8)
      )
    )
    let telegram = TelegramClient(token: "T", http: http, baseURL: "https://example.test")

    // when
    try await telegram.setMyCommands([
      BotMenuCommand(command: "start", description: "Start the bot."),
      BotMenuCommand(command: "new", description: "Start a new session."),
      BotMenuCommand(command: "stop", description: "Stop the current run."),
    ])

    // then
    let call = try #require(await recorder.calls.first)
    let body = try #require(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
    let commands = try #require(body["commands"] as? [[String: Any]])
    #expect(call.url == "https://example.test/botT/setMyCommands")
    #expect(commands.count == 3)
    #expect(commands[0]["command"] as? String == "start")
    #expect(commands[0]["description"] as? String == "Start the bot.")
    #expect(commands[1]["command"] as? String == "new")
    #expect(commands[2]["command"] as? String == "stop")
  }

  @Test func sendsRichMessageDraftWithDraftIdAndMarkdown() async throws {
    // given
    let recorder = RecordingHTTPExecutor.Recorder()
    let http = RecordingHTTPExecutor(
      recorder: recorder,
      result: HTTPResult(
        statusCode: 200,
        headers: [:],
        body: Data(#"{"ok":true,"result":true}"#.utf8)
      )
    )
    let telegram = TelegramClient(token: "T", http: http, baseURL: "https://example.test")

    // when
    let sent = try await telegram.sendRichMessageDraft(chatId: 42, draftId: 99, markdown: "**hi**")

    // then
    #expect(sent)
    let call = try #require(await recorder.calls.first)
    let body = try #require(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
    let richMessage = try #require(body["rich_message"] as? [String: Any])
    #expect(call.url == "https://example.test/botT/sendRichMessageDraft")
    #expect(call.timeout == 15)
    #expect(body["chat_id"] as? Int == 42)
    #expect(body["draft_id"] as? Int == 99)
    #expect(richMessage["markdown"] as? String == "**hi**")
  }
}
