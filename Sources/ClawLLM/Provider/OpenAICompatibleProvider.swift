import ClawCore
import Foundation
import Logging

/// OpenAI-compatible Chat Completions client over the `HTTPExecuting` seam: request shaping
/// (output-cap field switch, no sampling params), defensive response parse, status→`ProviderError`
/// mapping, and retry with `Retry-After`-aware backoff. Storeless — budget persistence is upstream.
public struct OpenAICompatibleProvider: LLMProvider {
  private let config: LLMConfig
  private let http: any HTTPExecuting & HTTPStreaming
  private let sleep: @Sendable (Double) async throws -> Void
  private let jitter: @Sendable (Double) -> Double
  /// Developer-facing diagnostics (swift-log). Lines self-tag `[ClawLLM]` via the source module; a
  /// no-op default keeps tests silent unless they inject one. Carries no run id by design — the
  /// per-turn correlation lives in `AgentRuntime`, so the `LLMProvider` contract stays unchanged.
  private let logger: Logger

  public init(
    config: LLMConfig,
    http: any HTTPExecuting & HTTPStreaming,
    sleep: @escaping @Sendable (Double) async throws -> Void,
    jitter: @escaping @Sendable (Double) -> Double,
    logger: Logger = Logger(label: "clawd.llm", factory: { _ in SwiftLogNoOpLogHandler() })
  ) {
    self.config = config
    self.http = http
    self.sleep = sleep
    self.jitter = jitter
    self.logger = logger
  }

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    let body = try encode(request: request)
    let url = chatCompletionsURL()
    let headers = requestHeaders()

    logger.debug(
      "chat request model=\(request.model) messages=\(request.messages.count) tools=\(request.tools.count)"
    )

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
        logger.notice(
          "chat transport error (attempt \(attempt)/\(config.retryBudget)); retrying: \(message)"
        )
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

      logger.notice(
        "chat retryable status \(result.statusCode) (attempt \(attempt)/\(config.retryBudget)); retrying"
      )
      try await backoff(attempt: attempt, retryAfterSeconds: retryAfterSeconds(from: result))
    }
  }

  public func stream(request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let body = try encode(request: request, streaming: true)
          logger.debug(
            "chat stream request model=\(request.model) messages=\(request.messages.count) tools=\(request.tools.count)"
          )
          let response = try await http.postStream(
            url: chatCompletionsURL(),
            headers: requestHeaders(),
            jsonBody: body,
            timeoutSeconds: config.requestTimeoutSeconds
          )

          guard (200..<300).contains(response.head.statusCode) else {
            let errorBody = try await collectStreamingErrorBody(response.body)
            let message = sanitize(message: errorMessage(from: errorBody))
            logger.notice("chat stream status \(response.head.statusCode)")

            if Self.isRetryableStatus(response.head.statusCode) {
              throw ProviderError.rejected(status: response.head.statusCode, message: message)
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

  func encode(request: ChatRequest, streaming: Bool = false) throws -> Data {
    let wireMessages = request.messages.map { message -> WireMessage in
      let wireCalls = message.toolCalls.map { call in
        WireToolCall(
          id: call.id,
          type: "function",
          function: WireToolCallFunction(name: call.name, arguments: call.argumentsJSON)
        )
      }
      // An empty-content assistant proposal omits `content` (some providers reject "" + tool_calls).
      let omitContent = message.role == .assistant && message.content.isEmpty && !wireCalls.isEmpty
      return WireMessage(
        role: message.role.rawValue,
        content: omitContent ? nil : message.content,
        toolCalls: wireCalls.isEmpty ? nil : wireCalls,
        toolCallId: message.toolCallId
      )
    }
    let wireTools = request.tools.map { definition in
      WireToolDefinition(
        type: "function",
        function: WireToolDefinition.Function(
          name: definition.name,
          description: definition.description,
          parameters: definition.parameters
        )
      )
    }
    let payload = RequestBody(
      model: request.model,
      messages: wireMessages,
      maxTokensKey: config.maxTokensField.rawValue,
      maxOutputTokens: request.maxOutputTokens,
      stop: request.stop,
      stream: streaming,
      streamOptions: streaming ? StreamOptions(includeUsage: true) : nil,
      tools: wireTools.isEmpty ? nil : wireTools
    )
    return try JSONEncoder().encode(payload)
  }

  func parse(result: HTTPResult) throws -> ChatResponse {
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
    let providerCost = decoded.usage?.cost ?? providerCost(from: result)

    let toolCalls = (choice?.message.toolCalls ?? []).compactMap { decoded -> ToolCall? in
      guard let callId = decoded.id, let name = decoded.function?.name else {
        return nil
      }
      return ToolCall(id: callId, name: name, argumentsJSON: decoded.function?.arguments ?? "{}")
    }

    return ChatResponse(
      content: choice?.message.content ?? "",
      finishReason: choice?.finishReason,
      usage: usage,
      costFromProvider: providerCost,
      toolCalls: toolCalls
    )
  }
}

// MARK: - Request

private extension OpenAICompatibleProvider {
  func chatCompletionsURL() -> String {
    let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
    return "\(base)/chat/completions"
  }

  func requestHeaders() -> [String: String] {
    var headers = ["Content-Type": "application/json"]
    if !config.apiKey.isEmpty {
      headers["Authorization"] = "Bearer \(config.apiKey)"
    }
    return headers
  }
}

// MARK: - Response

private extension OpenAICompatibleProvider {
  static let maxStreamingErrorBodyBytes = 64 * 1024
  static let liteLLMResponseCostHeader = "x-litellm-response-cost"

  func errorMessage(from body: Data) -> String {
    guard
      let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body),
      let message = decoded.error?.message
    else {
      return String(data: body, encoding: .utf8) ?? "unknown error"
    }
    return message
  }

  func collectStreamingErrorBody(
    _ body: AsyncThrowingStream<Data, Error>
  ) async throws -> Data {
    var collected = Data()

    for try await chunk in body {
      collected.append(chunk)
      if collected.count > Self.maxStreamingErrorBodyBytes {
        break
      }
    }

    return collected
  }

  func providerCost(from head: HTTPStreamHead) -> Double? {
    head.getHeader(for: Self.liteLLMResponseCostHeader).flatMap(Double.init)
  }

  func providerCost(from result: HTTPResult) -> Double? {
    result.getHeader(for: Self.liteLLMResponseCostHeader).flatMap(Double.init)
  }
}

// MARK: - Retry

private extension OpenAICompatibleProvider {
  static let baseBackoffSeconds = 0.5
  static let maxBackoffSeconds = 30.0

  func retryAfterSeconds(from result: HTTPResult) -> Double? {
    if let milliseconds = result.getHeader(for: "retry-after-ms").flatMap(Double.init) {
      return milliseconds / 1000
    }
    return result.getHeader(for: "retry-after").flatMap(Double.init)
  }

  func backoff(attempt: Int, retryAfterSeconds: Double?) async throws {
    if let retryAfter = retryAfterSeconds {
      try await sleep(retryAfter)
      return
    }
    let exponential = Self.baseBackoffSeconds * pow(2, Double(attempt - 1))
    try await sleep(jitter(min(exponential, Self.maxBackoffSeconds)))
  }
}

// MARK: - Redaction

private extension OpenAICompatibleProvider {
  func sanitize(message: String) -> String {
    guard !config.apiKey.isEmpty else {
      return message
    }
    return message.replacingOccurrences(of: config.apiKey, with: "<redacted-key>")
  }

  func sanitize(providerError: ProviderError) -> ProviderError {
    switch providerError {
    case .connectFailed(let message):
      return .connectFailed(message: sanitize(message: message))
    case .retryable(let status, let message):
      return .retryable(status: status, message: sanitize(message: message))
    case .rejected(let status, let message):
      return .rejected(status: status, message: sanitize(message: message))
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

private struct WireToolCallFunction: Codable {
  let name: String
  let arguments: String
}

private struct WireToolCall: Codable {
  let id: String
  let type: String
  let function: WireToolCallFunction
}

private struct WireToolDefinition: Encodable {
  struct Function: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
  }

  let type: String
  let function: Function
}

private struct WireMessage: Encodable {
  let role: String
  let content: String?
  // swiftlint:disable:next discouraged_optional_collection
  let toolCalls: [WireToolCall]?
  let toolCallId: String?

  enum CodingKeys: String, CodingKey {
    case role
    case content
    case toolCalls = "tool_calls"
    case toolCallId = "tool_call_id"
  }
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
  // swiftlint:disable:next discouraged_optional_collection
  let tools: [WireToolDefinition]?

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: DynamicKey.self)
    try container.encode(model, forKey: DynamicKey("model"))
    try container.encode(messages, forKey: DynamicKey("messages"))
    try container.encode(maxOutputTokens, forKey: DynamicKey(maxTokensKey))
    try container.encode(stream, forKey: DynamicKey("stream"))
    try container.encodeIfPresent(streamOptions, forKey: DynamicKey("stream_options"))
    try container.encodeIfPresent(stop, forKey: DynamicKey("stop"))
    try container.encodeIfPresent(tools, forKey: DynamicKey("tools"))
  }
}

private struct StreamOptions: Encodable {
  let includeUsage: Bool

  enum CodingKeys: String, CodingKey {
    case includeUsage = "include_usage"
  }
}

private struct DecodedToolCall: Decodable {
  struct Function: Decodable {
    let name: String?
    let arguments: String?
  }

  let id: String?
  let function: Function?
}

private struct ResponseBody: Decodable {
  struct Choice: Decodable {
    struct Message: Decodable {
      let content: String?
      // swiftlint:disable:next discouraged_optional_collection
      let toolCalls: [DecodedToolCall]?

      enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
      }
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
