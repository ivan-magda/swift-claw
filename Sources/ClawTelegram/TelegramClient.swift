import ClawCore
import Foundation

public struct TelegramClient: TelegramTransport {
  /// Default slack added on top of the long-poll timeout so the socket outlives the poll.
  public static let defaultHTTPTimeoutSlackSeconds = 15

  private let token: String
  private let http: any HTTPExecuting
  private let baseURL: String
  /// HTTP read timeout must exceed the long-poll timeout so the socket doesn't fire first.
  private let httpTimeoutSlackSeconds: Int

  public init(
    token: String,
    http: any HTTPExecuting,
    baseURL: String = "https://api.telegram.org",
    httpTimeoutSlackSeconds: Int = TelegramClient.defaultHTTPTimeoutSlackSeconds
  ) {
    self.token = token
    self.http = http
    self.baseURL = baseURL
    self.httpTimeoutSlackSeconds = httpTimeoutSlackSeconds
  }

  public func getMe() async throws -> BotIdentity {
    let user: TUser = try await callMethod("getMe", httpTimeout: Timeout.shortRequestSeconds)
    return BotIdentity(id: user.id, username: user.username)
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
    return updates.map { $0.toRawUpdate() }
  }

  public func sendMessage(chatId: Int64, text: String) async throws {
    let request = SendMessageRequest(chatId: chatId, text: text)
    let _: TMessage = try await callMethod(
      "sendMessage",
      body: request,
      httpTimeout: Timeout.sendMessageSeconds
    )
  }
}

// MARK: - Bot API transport

extension TelegramClient {
  private enum Timeout {
    static let shortRequestSeconds = 15
    static let sendMessageSeconds = 30
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
      payload = try body.map { try Self.encoder.encode($0) } ?? Data("{}".utf8)
    } catch {
      throw TelegramError.transport(sanitize("encode \(methodName): \(error)"))
    }

    let result: HTTPResult
    do {
      result = try await http.post(
        url: "\(baseURL)/bot\(token)/\(methodName)",
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
    if token.isEmpty {
      message
    } else {
      message.replacingOccurrences(of: token, with: "<redacted-token>")
    }
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

private struct SendMessageRequest: Encodable {
  let chatId: Int64
  let text: String
}
