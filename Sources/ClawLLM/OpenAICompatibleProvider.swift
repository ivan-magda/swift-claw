import ClawCore
import Foundation

/// OpenAI-compatible Chat Completions client over the `HTTPExecuting` seam: request shaping
/// (output-cap field switch, no sampling params), defensive response parse, status→`ProviderError`
/// mapping, and retry with `Retry-After`-aware backoff. Storeless — budget persistence is upstream.
public struct OpenAICompatibleProvider: LLMProvider {
  private static let baseBackoffSeconds = 0.5
  private static let maxBackoffSeconds = 30.0

  private let config: LLMConfig
  private let http: any HTTPExecuting & HTTPStreaming
  private let sleep: @Sendable (Double) async throws -> Void
  private let jitter: @Sendable (Double) -> Double

  public init(
    config: LLMConfig,
    http: any HTTPExecuting & HTTPStreaming,
    sleep: @escaping @Sendable (Double) async throws -> Void,
    jitter: @escaping @Sendable (Double) -> Double
  ) {
    self.config = config
    self.http = http
    self.sleep = sleep
    self.jitter = jitter
  }

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    let body = try encode(request: request)
    let url = chatCompletionsURL()
    let headers = requestHeaders()

    var attempt = 0
    while true {
      attempt += 1

      let result: HTTPResult
      do {
        result = try await http.post(
          url: url,
          headers: headers,
          jsonBody: body,
          timeoutSeconds: config.requestTimeoutSeconds
        )
      } catch {
        // Transport failures are retryable; the message may echo the key, so redact it.
        let message = sanitize(message: "\(error)")
        guard attempt < config.retryBudget else {
          throw ProviderError.retryable(status: nil, message: message)
        }
        try await backoff(attempt: attempt, retryAfterSeconds: nil)
        continue
      }

      if (200..<300).contains(result.statusCode) {
        return try parse(result: result)
      }

      let message = sanitize(message: errorMessage(from: result.body))
      guard Self.isRetryableStatus(result.statusCode) else {
        throw ProviderError.terminal(status: result.statusCode, message: message)
      }
      guard attempt < config.retryBudget else {
        throw ProviderError.retryable(status: result.statusCode, message: message)
      }
      try await backoff(attempt: attempt, retryAfterSeconds: retryAfterSeconds(from: result))
    }
  }

  public func stream(request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let body = try encode(request: request, streaming: true)
          let response = try await http.postStream(
            url: chatCompletionsURL(),
            headers: requestHeaders(),
            jsonBody: body,
            timeoutSeconds: config.requestTimeoutSeconds
          )

          guard (200..<300).contains(response.head.statusCode) else {
            let message = sanitize(message: errorMessage(from: try await collect(response.body)))
            if Self.isRetryableStatus(response.head.statusCode) {
              throw ProviderError.retryable(status: response.head.statusCode, message: message)
            }
            throw ProviderError.terminal(status: response.head.statusCode, message: message)
          }

          var parser = SSEParser(fallbackProviderCost: providerCost(from: response.head))
          for try await chunk in response.body {
            for event in try parser.push(chunk) {
              continuation.yield(event)
            }
          }
          if let finished = try parser.finish() {
            continuation.yield(finished)
          }
          continuation.finish()
        } catch let error as ProviderError {
          continuation.finish(throwing: sanitize(providerError: error))
        } catch {
          continuation.finish(
            throwing: ProviderError.retryable(status: nil, message: sanitize(message: "\(error)"))
          )
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static func isRetryableStatus(_ status: Int) -> Bool {
    status == 408 || status == 429 || (500..<600).contains(status)
  }

  /// Reasoning models reject sampling params; detection is forward-looking (Inc 1 sends none).
  static func isReasoningModel(_ model: String) -> Bool {
    model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") || model.hasPrefix("o-")
      || model.contains("reasoning")
  }

  // MARK: - Request

  private func chatCompletionsURL() -> String {
    let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
    return "\(base)/chat/completions"
  }

  private func requestHeaders() -> [String: String] {
    var headers = ["Content-Type": "application/json"]
    if !config.apiKey.isEmpty {
      headers["Authorization"] = "Bearer \(config.apiKey)"
    }
    return headers
  }

  private func encode(request: ChatRequest, streaming: Bool = false) throws -> Data {
    let payload = RequestBody(
      model: request.model,
      messages: request.messages.map { WireMessage(role: $0.role.rawValue, content: $0.content) },
      maxTokensKey: config.maxTokensField.rawValue,
      maxOutputTokens: request.maxOutputTokens,
      stop: request.stop,
      stream: streaming,
      streamOptions: streaming ? StreamOptions(includeUsage: true) : nil
    )
    return try JSONEncoder().encode(payload)
  }

  // MARK: - Response

  private func parse(result: HTTPResult) throws -> ChatResponse {
    let decoded: ResponseBody
    do {
      decoded = try JSONDecoder().decode(ResponseBody.self, from: result.body)
    } catch {
      throw ProviderError.terminal(
        status: result.statusCode,
        message: sanitize(message: "malformed response: \(error)")
      )
    }

    let choice = decoded.choices.first
    let usage =
      decoded.usage.map {
        ChatUsage(
          promptTokens: $0.promptTokens ?? 0,
          completionTokens: $0.completionTokens ?? 0,
          totalTokens: $0.totalTokens ?? 0
        )
      }
    // OpenRouter reports cost in usage.cost; LiteLLM in a response header.
    let providerCost =
      decoded.usage?.cost ?? result.getHeader(for: "x-litellm-response-cost").flatMap(Double.init)

    return ChatResponse(
      content: choice?.message.content ?? "",
      finishReason: choice?.finishReason,
      usage: usage,
      costFromProvider: providerCost
    )
  }

  private func errorMessage(from body: Data) -> String {
    guard
      let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body),
      let message = decoded.error?.message
    else {
      return String(data: body, encoding: .utf8) ?? "unknown error"
    }
    return message
  }

  private func collect(_ body: AsyncThrowingStream<Data, Error>) async throws -> Data {
    var collected = Data()
    for try await chunk in body {
      collected.append(chunk)
      if collected.count > 64 * 1024 {
        break
      }
    }
    return collected
  }

  private func providerCost(from head: HTTPStreamHead) -> Double? {
    head.getHeader(for: "x-litellm-response-cost").flatMap(Double.init)
  }

  // MARK: - Retry

  private func retryAfterSeconds(from result: HTTPResult) -> Double? {
    if let milliseconds = result.getHeader(for: "retry-after-ms").flatMap(Double.init) {
      return milliseconds / 1000
    }
    return result.getHeader(for: "retry-after").flatMap(Double.init)
  }

  private func backoff(attempt: Int, retryAfterSeconds: Double?) async throws {
    if let retryAfter = retryAfterSeconds {
      try await sleep(retryAfter)
      return
    }
    let exponential = Self.baseBackoffSeconds * pow(2, Double(attempt - 1))
    try await sleep(jitter(min(exponential, Self.maxBackoffSeconds)))
  }

  // MARK: - Redaction

  private func sanitize(message: String) -> String {
    guard !config.apiKey.isEmpty else {
      return message
    }
    return message.replacingOccurrences(of: config.apiKey, with: "<redacted-key>")
  }

  private func sanitize(providerError: ProviderError) -> ProviderError {
    switch providerError {
    case .connectFailed(let message):
      return .connectFailed(message: sanitize(message: message))
    case .retryable(let status, let message):
      return .retryable(status: status, message: sanitize(message: message))
    case .terminal(let status, let message):
      return .terminal(status: status, message: sanitize(message: message))
    }
  }
}

// MARK: - Wire models

private struct DynamicKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }

  init(_ stringValue: String) {
    self.stringValue = stringValue
  }

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    nil
  }
}

private struct WireMessage: Encodable {
  let role: String
  let content: String
}

private struct RequestBody: Encodable {
  let model: String
  let messages: [WireMessage]
  let maxTokensKey: String
  let maxOutputTokens: Int
  // swiftlint:disable:next discouraged_optional_collection
  let stop: [String]?
  let stream: Bool
  let streamOptions: StreamOptions?

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: DynamicKey.self)
    try container.encode(model, forKey: DynamicKey("model"))
    try container.encode(messages, forKey: DynamicKey("messages"))
    try container.encode(maxOutputTokens, forKey: DynamicKey(maxTokensKey))
    try container.encode(stream, forKey: DynamicKey("stream"))
    try container.encodeIfPresent(streamOptions, forKey: DynamicKey("stream_options"))
    try container.encodeIfPresent(stop, forKey: DynamicKey("stop"))
  }
}

private struct StreamOptions: Encodable {
  let includeUsage: Bool

  enum CodingKeys: String, CodingKey {
    case includeUsage = "include_usage"
  }
}

private struct ResponseBody: Decodable {
  struct Choice: Decodable {
    struct Message: Decodable {
      let content: String?
    }

    let message: Message
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
      case message
      case finishReason = "finish_reason"
    }
  }

  struct Usage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let cost: Double?

    enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
      case totalTokens = "total_tokens"
      case cost
    }
  }

  let choices: [Choice]
  let usage: Usage?
}

private struct ErrorBody: Decodable {
  struct Inner: Decodable {
    let message: String?
  }

  let error: Inner?
}
