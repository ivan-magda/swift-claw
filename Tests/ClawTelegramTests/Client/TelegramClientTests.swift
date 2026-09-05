import Foundation
import Testing

@testable import ClawCore
@testable import ClawTelegram

struct MockHTTPExecutor: HTTPExecuting {
  let result: HTTPResult

  func execute(_ request: HTTPRequest) async throws -> HTTPResult { result }
}

/// Local to this suite: it answers with one canned result and records the fields the Telegram wire
/// tests assert over, which the shared `ClawTestSupport` double keys by URL rather than replaying.
struct RecordingHTTPExecutor: HTTPExecuting {
  struct Call: Sendable {
    let url: String
    let body: Data
    let timeout: Duration
  }

  actor Recorder {
    private(set) var calls: [Call] = []

    func append(url: String, body: Data, timeout: Duration) {
      calls.append(Call(url: url, body: body, timeout: timeout))
    }
  }

  let recorder: Recorder
  let result: HTTPResult

  func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    await recorder.append(
      url: request.url,
      body: request.body ?? Data(),
      timeout: request.timeout
    )
    return result
  }
}

/// Simulates a transport error whose description echoes the request URL (which carries the token).
struct URLEchoingExecutor: HTTPExecuting {
  struct URLEchoError: Error, CustomStringConvertible {
    let url: String
    var description: String { "connection failed for \(url)" }
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    throw URLEchoError(url: request.url)
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
      guard let telegramErr = error as? TelegramError else {
        return false
      }
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
      guard case TelegramError.transport(let message) = error else {
        return false
      }
      thrownMessage = message
      return true
    }

    // then
    let message = try #require(thrownMessage)
    #expect(message.contains("SECRET-123:abc") == false)
    #expect(message.contains(SecretRedactor.replacement))
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
    #expect(call.timeout == .seconds(15))
    #expect(body["chat_id"] as? Int == 42)
    #expect(body["draft_id"] as? Int == 99)
    #expect(richMessage["markdown"] as? String == "**hi**")
    let linkPreviewOptions = try #require(body["link_preview_options"] as? [String: Any])
    #expect(linkPreviewOptions["is_disabled"] as? Bool == true)
  }

  @Test func sendMessageDisablesLinkPreviews() async throws {
    // given: an exfil-approval prompt embeds an attacker-chosen URL in outbound text; Telegram
    // must never auto-fetch it to build a preview (ARCHITECTURE §12), regardless of the owner's
    // eventual answer.
    let recorder = RecordingHTTPExecutor.Recorder()
    let http = RecordingHTTPExecutor(
      recorder: recorder,
      result: HTTPResult(
        statusCode: 200,
        headers: [:],
        body: Data(#"{"ok":true,"result":{"message_id":7,"chat":{"id":42}}}"#.utf8)
      )
    )
    let telegram = TelegramClient(token: "T", http: http, baseURL: "https://example.test")

    // when
    let messageId = try await telegram.sendMessage(chatId: 42, text: "https://evil.example/exfil")

    // then
    #expect(messageId == 7)
    let call = try #require(await recorder.calls.first)
    let body = try #require(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
    #expect(body["chat_id"] as? Int == 42)
    #expect(body["text"] as? String == "https://evil.example/exfil")
    let linkPreviewOptions = try #require(body["link_preview_options"] as? [String: Any])
    #expect(linkPreviewOptions["is_disabled"] as? Bool == true)
  }

  @Test func getUpdatesSocketTimeoutIsLongPollTimeoutPlusTenSeconds() async throws {
    // given (§18-A3): the socket read timeout must outlive the long poll by exactly 10 s, so a
    // stalled poll is cut and re-issued instead of hanging the loop across a network gap
    let recorder = RecordingHTTPExecutor.Recorder()
    let telegram = TelegramClient(
      token: "T",
      http: RecordingHTTPExecutor(
        recorder: recorder,
        result: HTTPResult(
          statusCode: 200,
          headers: [:],
          body: Data(#"{"ok":true,"result":[]}"#.utf8)
        )
      ),
      baseURL: "https://example.test"
    )

    // when
    _ = try await telegram.getUpdates(offset: nil, timeout: 30, allowedUpdates: ["message"])

    // then
    let call = try #require(await recorder.calls.first)
    #expect(call.timeout == .seconds(40))
    #expect(TelegramClient.defaultHTTPTimeoutSlackSeconds == 10)
  }

  @Test func getUpdatesPutsNonNilOffsetOnTheWire() async throws {
    // given
    let recorder = RecordingHTTPExecutor.Recorder()
    let http = RecordingHTTPExecutor(
      recorder: recorder,
      result: HTTPResult(
        statusCode: 200,
        headers: [:],
        body: Data(#"{"ok":true,"result":[]}"#.utf8)
      )
    )
    let telegram = TelegramClient(token: "T", http: http, baseURL: "https://example.test")

    // when
    _ = try await telegram.getUpdates(offset: 500, timeout: 30, allowedUpdates: ["message"])

    // then — the concrete offset (and allowed_updates) ride in the POST body
    let call = try #require(await recorder.calls.first)
    let body = try #require(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
    #expect(call.url == "https://example.test/botT/getUpdates")
    #expect(body["offset"] as? Int == 500)
    #expect(body["timeout"] as? Int == 30)
    #expect(body["allowed_updates"] as? [String] == ["message"])
  }
}
