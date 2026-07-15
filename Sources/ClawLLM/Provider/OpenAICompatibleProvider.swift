import ClawCore
import Foundation
import Logging

/// OpenAI-compatible Chat Completions client over the `HTTPExecuting` seam: request shaping
/// (output-cap field switch, no sampling params), defensive response parse, status→`ProviderError`
/// mapping, and retry with `Retry-After`-aware backoff. Storeless — budget persistence is upstream.
public struct OpenAICompatibleProvider: LLMProvider {
  private let config: LLMConfig
  private let http: any HTTPExecuting & HTTPStreaming

  private let clock: any Clock<Duration>
  private let jitter: @Sendable (Duration) -> Duration

  /// Developer-facing diagnostics (swift-log). Lines self-tag `[ClawLLM]` via the source module; a
  /// no-op default keeps tests silent unless they inject one. Carries no run id by design — the
  /// per-turn correlation lives in `AgentRuntime`, so the `LLMProvider` contract stays unchanged.
  private let logger: Logger

  public init(
    config: LLMConfig,
    http: any HTTPExecuting & HTTPStreaming,
    clock: any Clock<Duration>,
    jitter: @escaping @Sendable (Duration) -> Duration,
    logger: Logger = Logger(label: "clawd.llm", factory: { _ in SwiftLogNoOpLogHandler() })
  ) {
    self.config = config
    self.http = http

    self.clock = clock
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
        let message = sanitize(message: Self.describe(error))
        guard attempt < config.retryBudget else {
          throw ProviderError.retryable(status: nil, message: message)
        }
        logger.notice(
          "chat transport error (attempt \(attempt)/\(config.retryBudget)); retrying: \(message)"
        )
        try await backoff(attempt: attempt, retryAfter: nil)
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
      try await backoff(attempt: attempt, retryAfter: retryAfterDelay(from: result))
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
          let exchange = try await http.openStream(streamRequest(body: body))
          try await consume(exchange: exchange, into: continuation)
          continuation.finish()
        } catch let error as HTTPTransportFailure {
          continuation.finish(throwing: sanitize(providerError: Self.providerError(from: error)))
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

  static func baseURLIsOpenRouter(_ baseURL: String) -> Bool {
    URLComponents(string: baseURL)?.host?.lowercased() == "openrouter.ai"
  }

  /// Reasoning models reject sampling params; detection is forward-looking (none are sent yet).
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

    let sessionId = Self.baseURLIsOpenRouter(config.baseURL) ? request.sessionId : nil
    let payload = RequestBody(
      model: request.model,
      messages: wireMessages,
      maxTokensKey: config.maxTokensField.rawValue,
      maxOutputTokens: request.maxOutputTokens,
      stop: request.stop,
      stream: streaming,
      streamOptions: streaming ? StreamOptions(includeUsage: true) : nil,
      tools: wireTools.isEmpty ? nil : wireTools,
      responseFormat: request.responseFormat,
      sessionId: sessionId
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
      decoded.usage.map { wireUsage in
        wireUsage.toChatUsage()
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

// MARK: - Streaming

private extension OpenAICompatibleProvider {
  func streamRequest(body: Data) -> HTTPRequest {
    HTTPRequest(
      method: .post,
      url: chatCompletionsURL(),
      headers: requestHeaders(),
      body: body,
      timeoutSeconds: config.requestTimeoutSeconds,
      responseBodyPolicy: .streaming(
        maximumUnreadBytes: HTTPResponseBodyPolicy.maximumUnreadStreamBytes,
        errorBytes: Self.maxStreamingErrorBodyBytes
      )
    )
  }

  /// Reads the exchange and joins it on the way out, whichever way it ends. The exchange owns the
  /// transport work behind it, so returning without joining would leave that work running.
  func consume(
    exchange: HTTPStreamExchange,
    into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
  ) async throws {
    do {
      guard (200..<300).contains(exchange.head.statusCode) else {
        throw try await rejection(from: exchange)
      }

      var parser = SSEParser(fallbackProviderCost: providerCost(from: exchange.head))
      for try await chunk in exchange.body {
        for event in try parser.push(chunk) {
          continuation.yield(event)
        }
      }
      try Self.check(termination: await exchange.awaitTermination())

      if let finished = try parser.finish() {
        continuation.yield(finished)
      }
    } catch {
      _ = await exchange.cancelAndAwait()
      throw error
    }
  }

  /// The body of a non-success head. The executor has already capped it, so reading to the end holds
  /// no more than the diagnostic allowance.
  func rejection(from exchange: HTTPStreamExchange) async throws -> ProviderError {
    var collected = Data()
    for try await chunk in exchange.body {
      collected.append(chunk)
    }
    let message = sanitize(message: errorMessage(from: collected))
    logger.notice("chat stream status \(exchange.head.statusCode)")

    if Self.isRetryableStatus(exchange.head.statusCode) {
      return ProviderError.rejected(status: exchange.head.statusCode, message: message)
    }
    return ProviderError.terminal(status: exchange.head.statusCode, message: message)
  }

  /// The body sequence ending says only that no more bytes are coming; the termination says whether
  /// the transfer actually finished. A cancelled exchange closes its body cleanly, so trusting the
  /// sequence alone would read a truncated stream as a complete one.
  static func check(termination: HTTPStreamTermination) throws {
    switch termination {
    case .completed:
      return
    case .failed(let failure):
      throw providerError(from: failure)
    case .cancelled:
      throw CancellationError()
    }
  }

  /// Maps a transport failure by its typed disposition and never by its text. `definitelyNotSent` is
  /// precisely what `connectFailed` has always meant to callers: nothing reached the model, so the
  /// attempt can be replayed.
  static func providerError(from failure: HTTPTransportFailure) -> ProviderError {
    switch failure.disposition {
    case .definitelyNotSent:
      return .connectFailed(message: failure.safeMessage)
    case .mayHaveBeenSent:
      return .retryable(status: nil, message: failure.safeMessage)
    }
  }

  /// A transport failure already carries its own diagnostic; interpolating the struct would bury it
  /// in synthesized field syntax.
  static func describe(_ error: any Error) -> String {
    guard let failure = error as? HTTPTransportFailure else { return "\(error)" }
    return failure.safeMessage
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

  func retryAfterDelay(from result: HTTPResult) -> Duration? {
    if let milliseconds = result.getHeader(for: "retry-after-ms").flatMap(Double.init) {
      return .milliseconds(milliseconds)
    }
    return result.getHeader(for: "retry-after").flatMap(Double.init).map { .seconds($0) }
  }

  func backoff(attempt: Int, retryAfter: Duration?) async throws {
    if let retryAfter {
      try await clock.sleep(for: retryAfter)
      return
    }
    let exponentialSeconds = Self.baseBackoffSeconds * pow(2, Double(attempt - 1))
    let capped = Duration.seconds(min(exponentialSeconds, Self.maxBackoffSeconds))
    try await clock.sleep(for: jitter(capped))
  }
}

// MARK: - Redaction

private extension OpenAICompatibleProvider {
  func sanitize(message: String) -> String {
    SecretRedactor(secretValues: [config.apiKey]).redact(message)
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
  let responseFormat: ResponseFormat?
  let sessionId: String?

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: DynamicKey.self)

    try container.encode(model, forKey: DynamicKey("model"))
    try container.encode(messages, forKey: DynamicKey("messages"))
    try container.encode(maxOutputTokens, forKey: DynamicKey(maxTokensKey))
    try container.encode(stream, forKey: DynamicKey("stream"))
    try container.encodeIfPresent(streamOptions, forKey: DynamicKey("stream_options"))
    try container.encodeIfPresent(stop, forKey: DynamicKey("stop"))
    try container.encodeIfPresent(tools, forKey: DynamicKey("tools"))
    try container.encodeIfPresent(sessionId, forKey: DynamicKey("session_id"))

    if let responseFormat {
      try container.encode(
        WireResponseFormat(responseFormat: responseFormat),
        forKey: DynamicKey("response_format")
      )
    }
  }
}

private struct WireResponseFormat: Encodable {
  let responseFormat: ResponseFormat

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: DynamicKey.self)

    switch responseFormat {
    case .jsonObject:
      try container.encode("json_object", forKey: DynamicKey("type"))
    case .jsonSchema(let name, let schema):
      try container.encode("json_schema", forKey: DynamicKey("type"))
      try container.encode(
        WireJSONSchema(name: name, strict: true, schema: schema),
        forKey: DynamicKey("json_schema")
      )
    }
  }
}

private struct WireJSONSchema: Encodable {
  let name: String
  let strict: Bool
  let schema: JSONValue
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
  struct Message: Decodable {
    let content: String?
    // swiftlint:disable:next discouraged_optional_collection
    let toolCalls: [DecodedToolCall]?

    enum CodingKeys: String, CodingKey {
      case content
      case toolCalls = "tool_calls"
    }
  }

  struct Choice: Decodable {
    let message: Message
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
      case message
      case finishReason = "finish_reason"
    }
  }

  let choices: [Choice]
  let usage: WireUsage?
}

private struct ErrorBody: Decodable {
  struct Inner: Decodable {
    let message: String?
  }

  let error: Inner?
}
