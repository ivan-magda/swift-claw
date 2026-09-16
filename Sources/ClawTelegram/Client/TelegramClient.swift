import ClawCore
import Foundation

public struct TelegramClient: TelegramTransport {
  /// The getUpdates socket read timeout is the long-poll timeout + 10 s — enough for the server
  /// to flush a full batch after the poll window, small enough that a dead connection is
  /// detected within seconds, not minutes; the poller's backoff then reconnects. Scheduler-side
  /// gap recovery is lateness-based, no wake detection.
  public static let defaultHTTPTimeoutSlackSeconds = 10

  private let token: String
  private let http: any HTTPExecuting
  private let downloadHTTP: (any HTTPExecuting)?
  private let baseURL: String
  /// HTTP read timeout must exceed the long-poll timeout so the socket doesn't fire first.
  private let httpTimeoutSlackSeconds: Int

  public init(
    token: String,
    http: any HTTPExecuting,
    downloadHTTP: (any HTTPExecuting)? = nil,
    baseURL: String = "https://api.telegram.org",
    httpTimeoutSlackSeconds: Int = TelegramClient.defaultHTTPTimeoutSlackSeconds
  ) {
    self.token = token
    self.http = http
    self.downloadHTTP = downloadHTTP
    self.baseURL = baseURL
    self.httpTimeoutSlackSeconds = httpTimeoutSlackSeconds
  }

  public func getMe() async throws -> BotIdentity {
    let user: TUser = try await callMethod("getMe", httpTimeout: Timeout.shortRequestSeconds)
    return BotIdentity(id: user.id, username: user.username)
  }

  public func isCurrentMember(chatID: Int64, userID: Int64) async throws -> Bool {
    let request = GetChatMemberRequest(chatID: chatID, userID: userID)
    let member: TChatMemberLookup = try await callMethod(
      "getChatMember",
      body: request,
      httpTimeout: Timeout.shortRequestSeconds
    )
    guard member.user.id == userID else {
      return false
    }
    switch ChatMembershipStatus(apiValue: member.status) {
    case .creator, .administrator, .member:
      return true
    case .restricted:
      return member.is_member == true
    case .left, .kicked, .other:
      return false
    }
  }

  public func getUpdates(
    offset: Int64?,
    timeout: Int,
    allowedUpdates: [String]
  ) async throws -> [RawUpdate] {
    let request = GetUpdatesRequest(
      offset: offset,
      timeout: timeout,
      allowedUpdates: allowedUpdates
    )
    let updates: [TUpdate] = try await callMethod(
      "getUpdates",
      body: request,
      httpTimeout: timeout + httpTimeoutSlackSeconds
    )
    return updates.map {
      $0.toRawUpdate()
    }
  }

  public func sendMessage(
    to target: DeliveryTarget,
    text: String,
    replyMarkup: String?
  ) async throws -> Int64 {
    let request = SendMessageRequest(
      chatID: target.chatID,
      text: text,
      messageThreadID: target.messageThreadID,
      replyParameters: ReplyParameters(answering: target),
      linkPreviewOptions: LinkPreviewOptions(isDisabled: true),
      replyMarkup: replyMarkup.flatMap(JSONValue.parse)
    )
    let message: TMessage = try await callMethod(
      "sendMessage",
      body: request,
      httpTimeout: Timeout.sendMessageSeconds
    )
    return message.message_id
  }

  public func sendRichMessage(
    to target: DeliveryTarget,
    markdown: String,
    replyMarkup: String?
  ) async throws -> Int64 {
    let request = SendRichMessageRequest(
      chatID: target.chatID,
      richMessage: InputRichMessage(markdown: markdown),
      messageThreadID: target.messageThreadID,
      replyParameters: ReplyParameters(answering: target),
      linkPreviewOptions: LinkPreviewOptions(isDisabled: true),
      replyMarkup: replyMarkup.flatMap(JSONValue.parse)
    )
    let message: TMessage = try await callMethod(
      "sendRichMessage",
      body: request,
      httpTimeout: Timeout.sendMessageSeconds
    )
    return message.message_id
  }

  public func answerCallbackQuery(id: String, text: String?) async throws {
    let request = AnswerCallbackQueryRequest(callbackQueryID: id, text: text)
    let _: Bool = try await callMethod(
      "answerCallbackQuery",
      body: request,
      httpTimeout: Timeout.shortRequestSeconds
    )
  }

  public func editMessageReplyMarkup(
    chatID: Int64,
    messageID: Int64,
    replyMarkup: String?
  ) async throws {
    let request = EditMessageReplyMarkupRequest(
      chatID: chatID,
      messageID: messageID,
      replyMarkup: replyMarkup.flatMap(JSONValue.parse)
    )
    let _: JSONValue = try await callMethod(
      "editMessageReplyMarkup",
      body: request,
      httpTimeout: Timeout.shortRequestSeconds
    )
  }

  public func sendRichMessageDraft(
    chatID: Int64,
    draftID: Int64,
    markdown: String
  ) async throws -> Bool {
    let request = SendRichMessageDraftRequest(
      chatID: chatID,
      draftID: draftID,
      richMessage: InputRichMessage(markdown: markdown),
      linkPreviewOptions: LinkPreviewOptions(isDisabled: true)
    )
    return try await callMethod(
      "sendRichMessageDraft",
      body: request,
      httpTimeout: Timeout.shortRequestSeconds
    )
  }

  public func sendChatAction(chatID: Int64, messageThreadID: Int64?, action: String) async throws {
    let request = SendChatActionRequest(
      chatID: chatID,
      messageThreadID: messageThreadID,
      action: action
    )
    let _: Bool = try await callMethod(
      "sendChatAction",
      body: request,
      httpTimeout: Timeout.shortRequestSeconds
    )
  }

  public func setMyCommands(_ commands: [BotMenuCommand]) async throws {
    let request = SetMyCommandsRequest(commands: commands)
    let _: Bool = try await callMethod(
      "setMyCommands",
      body: request,
      httpTimeout: Timeout.shortRequestSeconds
    )
  }
}

// MARK: - Media file download

extension TelegramClient: MediaFetching {
  /// `getFile` then a bounded GET of `/file/bot<token>/<file_path>`. The URL carries the bot
  /// token, so every failure message passes through `sanitize` before it can be thrown or logged.
  public func downloadFile(fileID: String, maxBytes: Int) async throws -> Data {
    let request = GetFileRequest(fileID: fileID)
    let file: TFile = try await callMethod(
      "getFile",
      body: request,
      httpTimeout: Timeout.shortRequestSeconds
    )

    guard let path = file.file_path, isSafeFilePath(path) else {
      throw TelegramError.transport("getFile returned no usable file_path")
    }

    let result: HTTPResult
    do {
      result = try await (downloadHTTP ?? http).get(
        url: "\(baseURL)/file/bot\(token)/\(path)",
        headers: [:],
        timeoutSeconds: Timeout.fileDownloadSeconds,
        maxBodyBytes: maxBytes
      )
    } catch let overCap as HTTPTransportFailure where overCap.isOversizedBody(cap: maxBytes) {
      // Surfaced typed rather than flattened into a generic transport failure: a caller must be able
      // to tell "this file is past your ceiling" from "the download broke", and it is the only
      // signal available, since an over-cap body is refused outright instead of handed back short.
      // Its message is built from the cap alone, so it cannot echo the token-bearing URL.
      throw overCap
    } catch {
      throw TelegramError.transport(sanitize("media download: \(error)"))
    }

    guard result.statusCode == 200 else {
      throw TelegramError.apiError(code: result.statusCode, description: "media download failed")
    }

    return result.body
  }

  /// `file_path` is server-controlled text interpolated into a URL; refuse anything that could
  /// escape the `/file/bot<token>/` prefix (absolute paths, traversal, query/fragment splits).
  private func isSafeFilePath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.contains("..") && !path.contains("?")
      && !path.contains("#") && !path.contains("\\")
  }
}

// MARK: - Bot API transport

extension TelegramClient {
  private enum Timeout {
    static let shortRequestSeconds = 15
    static let sendMessageSeconds = 30
    static let fileDownloadSeconds = 60
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }()

  /// Encodes the parameters, POSTs to `/bot<token>/<methodName>`, then decodes the Bot API
  /// envelope into `Response` (or a typed `TelegramError`).
  private func callMethod<Response: Decodable>(
    _ methodName: String,
    body: (any Encodable)? = nil,
    httpTimeout: Int
  ) async throws -> Response {
    let payload: Data
    do {
      payload =
        try body.map {
          try Self.encoder.encode($0)
        } ?? Data("{}".utf8)
    } catch {
      throw TelegramError.transport(sanitize("encode \(methodName): \(error)"))
    }

    let result: HTTPResult
    do {
      result = try await http.post(
        url: "\(baseURL)/bot\(token)/\(methodName)",
        headers: [:],
        jsonBody: payload,
        timeoutSeconds: httpTimeout
      )
    } catch {
      throw TelegramError.transport(sanitize("\(methodName): \(error)"))
    }

    return try Self.decode(result)
  }

  /// Strips the bot token from any thrown/logged message so `TelegramError` is safe to log
  /// verbatim downstream (the token is in the request URL).
  private func sanitize(_ message: String) -> String {
    SecretRedactor(secretValues: [token]).redact(message)
  }

  /// Decodes the `TResponse<R>` envelope,
  /// returning `result` on success and mapping failures to typed `TelegramError` cases.
  static func decode<R: Decodable>(_ result: HTTPResult) throws -> R {
    let envelope: TResponse<R>
    do {
      envelope = try JSONDecoder().decode(TResponse<R>.self, from: result.body)
    } catch {
      throw TelegramError.decoding("status \(result.statusCode): \(error)")
    }

    if envelope.ok, let value = envelope.result {
      return value
    }

    let code = envelope.error_code ?? result.statusCode
    let description = envelope.description ?? "unknown error"
    switch code {
    case 409:
      throw TelegramError.conflict409(description: description)
    case 429:
      throw TelegramError.floodControl(retryAfter: envelope.parameters?.retry_after ?? 5)
    default:
      throw TelegramError.apiError(code: code, description: description)
    }
  }
}

private struct GetUpdatesRequest: Encodable {
  let offset: Int64?
  let timeout: Int
  let allowedUpdates: [String]
}

private struct GetFileRequest: Encodable {
  private enum CodingKeys: String, CodingKey {
    case fileID = "fileId"
  }

  let fileID: String
}

private struct GetChatMemberRequest: Encodable {
  private enum CodingKeys: String, CodingKey {
    case chatID = "chatId"
    case userID = "userId"
  }

  let chatID: Int64
  let userID: Int64
}

private struct SendMessageRequest: Encodable {
  private enum CodingKeys: String, CodingKey {
    case chatID = "chatId"
    case text
    case messageThreadID = "messageThreadId"
    case replyParameters
    case linkPreviewOptions
    case replyMarkup
  }

  let chatID: Int64
  let text: String
  let messageThreadID: Int64?
  let replyParameters: ReplyParameters?
  let linkPreviewOptions: LinkPreviewOptions
  let replyMarkup: JSONValue?
}

private struct SendRichMessageRequest: Encodable {
  private enum CodingKeys: String, CodingKey {
    case chatID = "chatId"
    case richMessage
    case messageThreadID = "messageThreadId"
    case replyParameters
    case linkPreviewOptions
    case replyMarkup
  }

  let chatID: Int64
  let richMessage: InputRichMessage
  let messageThreadID: Int64?
  let replyParameters: ReplyParameters?
  let linkPreviewOptions: LinkPreviewOptions
  let replyMarkup: JSONValue?
}

/// Bot API `ReplyParameters`. `allowSendingWithoutReply` is always on: a deleted target would
/// otherwise answer 400, and a permanently failing send stalls every later outbox row behind it.
private struct ReplyParameters: Encodable {
  private enum CodingKeys: String, CodingKey {
    case messageID = "messageId"
    case allowSendingWithoutReply
  }

  let messageID: Int64
  let allowSendingWithoutReply = true

  init?(answering target: DeliveryTarget) {
    guard let messageID = target.replyToMessageID else {
      return nil
    }
    self.messageID = messageID
  }
}

private struct SendChatActionRequest: Encodable {
  private enum CodingKeys: String, CodingKey {
    case chatID = "chatId"
    case messageThreadID = "messageThreadId"
    case action
  }

  let chatID: Int64
  let messageThreadID: Int64?
  let action: String
}

private struct SetMyCommandsRequest: Encodable {
  let commands: [BotMenuCommand]
}

private struct AnswerCallbackQueryRequest: Encodable {
  private enum CodingKeys: String, CodingKey {
    case callbackQueryID = "callbackQueryId"
    case text
  }

  let callbackQueryID: String
  let text: String?
}

private struct EditMessageReplyMarkupRequest: Encodable {
  private enum CodingKeys: String, CodingKey {
    case chatID = "chatId"
    case messageID = "messageId"
    case replyMarkup
  }

  let chatID: Int64
  let messageID: Int64
  let replyMarkup: JSONValue?
}

/// The Telegram-backed `TypingIndicator` the agent uses during a turn. Errors are swallowed: the
/// "typing…" action is cosmetic, auto-expires (~5s), and must never fail a turn.
public struct TelegramTypingIndicator: TypingIndicator {
  private let transport: any TelegramTransport

  public init(transport: any TelegramTransport) {
    self.transport = transport
  }

  public func sendTyping(chatID: Int64, messageThreadID: Int64?) async {
    try? await transport.sendChatAction(
      chatID: chatID,
      messageThreadID: messageThreadID,
      action: "typing"
    )
  }
}
