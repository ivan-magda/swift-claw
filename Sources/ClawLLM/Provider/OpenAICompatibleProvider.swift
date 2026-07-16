import ClawCore
import Foundation
import Logging

/// OpenAI-compatible Chat Completions client over the `HTTPExecuting` seam: request shaping
/// (output-cap field switch, no sampling params), defensive response parse, status→`ProviderError`
/// mapping, and retry with `Retry-After`-aware backoff. Storeless — budget persistence is upstream.
///
/// It owns the wire, never the credential: authorization arrives per request from an injected
/// source, and the only header that source may contribute is `Authorization`.
public struct OpenAICompatibleProvider: LLMProvider {
  private let config: LLMConfig
  /// The resolved endpoint the route selected. Kept as its own value rather than pulled back out of
  /// the route on every call: this adapter owns the wire URL and applies its own single-slash path
  /// rule to what it is handed, so the endpoint arrives already resolved and is never re-canonicalized
  /// here.
  private let endpoint: String
  /// Which JSON key carries the output cap on this route's wire. The route's descriptor decides it,
  /// so a second copy of the field-selection rule cannot drift from what configuration validated.
  private let maxTokensField: MaxTokensField
  private let credentials: any LLMCredentialSource
  private let http: any HTTPExecuting & HTTPStreaming

  private let backoff: RetryBackoff

  /// Developer-facing diagnostics (swift-log). Lines self-tag `[ClawLLM]` via the source module; a
  /// no-op default keeps tests silent unless they inject one. Carries no run id by design — the
  /// per-turn correlation lives in `AgentRuntime`, so the `LLMProvider` contract stays unchanged.
  private let logger: Logger

  public init(
    config: LLMConfig,
    endpoint: String,
    maxTokensField: MaxTokensField,
    credentials: any LLMCredentialSource,
    http: any HTTPExecuting & HTTPStreaming,
    clock: any Clock<Duration>,
    jitter: @escaping @Sendable (Duration) -> Duration,
    logger: Logger = Logger(label: "clawd.llm", factory: { _ in SwiftLogNoOpLogHandler() })
  ) {
    self.config = config
    self.endpoint = endpoint
    self.maxTokensField = maxTokensField
    self.credentials = credentials
    self.http = http

    self.backoff = RetryBackoff(
      clock: clock,
      jitter: jitter,
      requestTimeoutSeconds: config.requestTimeoutSeconds
    )

    self.logger = logger
  }

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    let body = try encode(request: request)
    let url = chatCompletionsURL()
    let exposure = ProviderAttemptExposure()

    let authorization: LLMRequestAuthorization
    do {
      authorization = try await credentials.authorization()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // No request goes out without a credential, so nothing was exposed. The cause names the state
      // rather than the source's error, which is what keeps key material out of the throw — there is
      // no redactor yet to scrub it with.
      throw ProviderError.authenticationRequired
    }

    let redactor = SecretRedactor(secretValues: authorization.redactionValues)
    let headers = try headers(for: authorization)

    logger.debug(
      "chat request model=\(request.model) messages=\(request.messages.count) tools=\(request.tools.count)"
    )

    var attempt = 0
    while true {
      attempt += 1

      let result: HTTPResult
      do {
        result = try await http.execute(
          bufferedRequest(url: url, headers: headers, body: body, exposure: exposure)
        )
      } catch is CancellationError {
        // The handoff refused, or the transport unwound: whether the model was asked anyway is the
        // reducer's to answer, and retrying a call the caller has abandoned would ask it again.
        throw exposure.cancellationError()
      } catch {
        // Transport failures are retryable; the message may echo the key, so redact it.
        Self.noteIfProvenClean(error, exposure: exposure)
        let message = redactor.redact(Self.describe(error))
        guard attempt < config.retryBudget else {
          // The exposure carries whether this attempt was proven clean, so the accounting rides the
          // failure rather than being guessed from the cause's case downstream.
          throw exposure.failure(.retryable(status: nil, message: message))
        }
        logger.notice(
          "chat transport error (attempt \(attempt)/\(config.retryBudget)); retrying: \(message)"
        )
        try await backoff.wait(retryAfter: nil, attempt: attempt)
        continue
      }

      if (200..<300).contains(result.statusCode) {
        do {
          return try parse(result: result, redactor: redactor)
        } catch let cause as ProviderError {
          // The 2xx head was accepted, so the reply was generated and billed. A body we cannot read
          // is still a failure that must record conservative usage rather than none, so the exposure
          // (still `mayHaveStarted` here) travels on the failure.
          throw exposure.failure(cause)
        }
      }

      // The server answered instead of inferring, so this attempt generated nothing.
      exposure.noteProvenClean()
      let message = redactor.redact(errorMessage(from: result.body))
      guard Self.isRetryableStatus(result.statusCode) else {
        throw exposure.failure(.terminal(status: result.statusCode, message: message))
      }
      guard attempt < config.retryBudget else {
        // Proven clean above, so the failure carries `notStarted` and no phantom usage is debited for
        // a reply the server rejected before generating.
        throw exposure.failure(.retryable(status: result.statusCode, message: message))
      }

      logger.notice(
        "chat retryable status \(result.statusCode) (attempt \(attempt)/\(config.retryBudget)); retrying"
      )
      try await backoff.wait(retryAfter: retryAfterDelay(from: result), attempt: attempt)
    }
  }

  public func stream(request: ChatRequest) -> LLMEventStream {
    LLMEventStream.make { sink in
      await infer(request: request, into: sink)
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

    let sessionId = Self.baseURLIsOpenRouter(endpoint) ? request.sessionId : nil
    let payload = RequestBody(
      model: request.model,
      messages: wireMessages,
      maxTokensKey: maxTokensField.rawValue,
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

  func parse(result: HTTPResult, redactor: SecretRedactor) throws -> ChatResponse {
    let decoded: ResponseBody
    do {
      decoded = try JSONDecoder().decode(ResponseBody.self, from: result.body)
    } catch {
      throw ProviderError.terminal(
        status: result.statusCode,
        message: redactor.redact("malformed response: \(error)")
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
  /// The whole streamed inference, reported rather than thrown: the session owns this operation, so
  /// its return value *is* the outcome the session caches and hands to every joiner.
  func infer(request: ChatRequest, into sink: LLMEventSink) async -> LLMStreamTermination {
    let exposure = ProviderAttemptExposure()

    let authorization: LLMRequestAuthorization
    do {
      authorization = try await credentials.authorization()
    } catch is CancellationError {
      return .cancelled(.notStarted)
    } catch {
      // No request goes out without a credential, so nothing was exposed. The cause names the state
      // rather than the source's error, which is what keeps key material out of the terminal.
      return .failed(ProviderFailure(cause: .authenticationRequired, accounting: .notStarted))
    }

    let redactor = SecretRedactor(secretValues: authorization.redactionValues)
    do {
      let body = try encode(request: request, streaming: true)
      let headers = try headers(for: authorization)
      logger.debug(
        "chat stream request model=\(request.model) messages=\(request.messages.count) tools=\(request.tools.count)"
      )
      let exchange = try await http.openStream(
        streamRequest(headers: headers, body: body, exposure: exposure)
      )
      return await consume(exchange: exchange, into: sink, exposure: exposure, redactor: redactor)
    } catch {
      return Self.termination(for: error, exposure: exposure, redactor: redactor)
    }
  }

  func streamRequest(
    headers: [String: String],
    body: Data,
    exposure: ProviderAttemptExposure
  ) -> HTTPRequest {
    HTTPRequest(
      method: .post,
      url: chatCompletionsURL(),
      headers: headers,
      body: body,
      timeoutSeconds: config.requestTimeoutSeconds,
      responseBodyPolicy: .streaming(
        maximumUnreadBytes: HTTPResponseBodyPolicy.maximumUnreadStreamBytes,
        errorBytes: HTTPResponseBodyPolicy.diagnosticBodyBytes
      ),
      beginHandoff: { try exposure.beginHandoff() }
    )
  }

  /// Reads the exchange and joins it on the way out, whichever way it ends. The exchange owns the
  /// transport work behind it, so returning without joining would leave that work running — and the
  /// session's own joiners would be told the inference had stopped while it had not.
  func consume(
    exchange: HTTPStreamExchange,
    into sink: LLMEventSink,
    exposure: ProviderAttemptExposure,
    redactor: SecretRedactor
  ) async -> LLMStreamTermination {
    do {
      guard (200..<300).contains(exchange.head.statusCode) else {
        // A recognized non-success head proves the server answered instead of inferring, so the
        // attempt returns to `notStarted` before its diagnostic body is even read.
        exposure.noteProvenClean()
        let cause = try await rejection(from: exchange, redactor: redactor)
        _ = await exchange.cancelAndAwait()
        return .failed(ProviderFailure(cause: cause, accounting: exposure.accounting))
      }

      var parser = SSEParser(fallbackProviderCost: providerCost(from: exchange.head))
      var terminal: ChatResponse?
      for try await chunk in exchange.body {
        for event in try parser.push(chunk) {
          switch event {
          case .delta(let text):
            try await sink.sendDelta(text)
          case .finished(let response):
            terminal = response
          }
        }
        exposure.noteObserved(completionTokens: parser.observedCompletionTokens)
      }
      try Self.check(termination: await exchange.awaitTermination())

      if case .finished(let response)? = try parser.finish() {
        terminal = response
      }
      // A server that closed without a `[DONE]` still delivered a reply; the parser's accumulation
      // is it.
      return .completed(terminal ?? parser.assembledResponse)
    } catch {
      _ = await exchange.cancelAndAwait()
      return Self.termination(for: error, exposure: exposure, redactor: redactor)
    }
  }

  /// The outcome a natural failure reports. Cancellation is reported as cancellation rather than
  /// dressed up as a provider failure, so a joiner can tell "we stopped it" from "it broke".
  static func termination(
    for error: any Error,
    exposure: ProviderAttemptExposure,
    redactor: SecretRedactor
  ) -> LLMStreamTermination {
    if error is CancellationError {
      return .cancelled(exposure.accounting)
    }
    noteIfProvenClean(error, exposure: exposure)
    return .failed(
      ProviderFailure(
        cause: cause(for: error).redacted(with: redactor),
        accounting: exposure.accounting
      )
    )
  }

  static func cause(for error: any Error) -> ProviderError {
    if let failure = error as? HTTPTransportFailure {
      return providerError(from: failure)
    }
    if let providerError = error as? ProviderError {
      return providerError
    }
    return .retryable(status: nil, message: "\(error)")
  }

  /// Only a transport fact may return an attempt to `notStarted`; an error's text never can.
  static func noteIfProvenClean(_ error: any Error, exposure: ProviderAttemptExposure) {
    guard
      let failure = error as? HTTPTransportFailure,
      failure.disposition == .definitelyNotSent
    else {
      return
    }
    exposure.noteProvenClean()
  }

  /// The body of a non-success head. The executor has already capped it, so reading to the end holds
  /// no more than the diagnostic allowance.
  func rejection(
    from exchange: HTTPStreamExchange,
    redactor: SecretRedactor
  ) async throws -> ProviderError {
    var collected = Data()
    for try await chunk in exchange.body {
      collected.append(chunk)
    }
    let message = redactor.redact(errorMessage(from: collected))
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
  /// The headers this adapter puts on the wire itself. Everything about how the exchange is framed
  /// belongs here rather than to whoever supplies the credential.
  static let adapterHeaders = ["Content-Type": "application/json"]

  /// The only header a credential source may contribute to this route, keyed by its normalized name
  /// and mapped to the single spelling that reaches the wire.
  static let allowedCredentialHeaders = ["authorization": "Authorization"]

  func chatCompletionsURL() -> String {
    let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
    return "\(base)/chat/completions"
  }

  /// Folds the credential source's contribution into this adapter's own headers.
  ///
  /// The seam is a plain dictionary, so without an allowlist any source could rewrite `Host`,
  /// content negotiation, client identity, or session routing on the way to the wire. A name outside
  /// the allowlist, or one the adapter already owns, is refused rather than merged — and the refusal
  /// quotes only the name, never the value it came with.
  ///
  /// Merging under the allowlist's own spelling rather than the source's keeps the dictionary from
  /// seating two casings of one header, which the wire would carry as two headers.
  func headers(for authorization: LLMRequestAuthorization) throws -> [String: String] {
    try CredentialHeaderMerge.merged(
      into: Self.adapterHeaders,
      allowing: Self.allowedCredentialHeaders,
      from: authorization
    )
  }

  /// The blocking request. `execute` rather than the `post` convenience because only the general
  /// form carries the handoff that linearizes this attempt's exposure; the caps match what `post`
  /// would have supplied.
  func bufferedRequest(
    url: String,
    headers: [String: String],
    body: Data,
    exposure: ProviderAttemptExposure
  ) -> HTTPRequest {
    HTTPRequest(
      method: .post,
      url: url,
      headers: headers,
      body: body,
      timeoutSeconds: config.requestTimeoutSeconds,
      responseBodyPolicy: .buffered(
        successBytes: HTTPResponseBodyPolicy.defaultBufferedBodyBytes,
        errorBytes: HTTPResponseBodyPolicy.defaultBufferedBodyBytes
      ),
      beginHandoff: { try exposure.beginHandoff() }
    )
  }
}

// MARK: - Response

private extension OpenAICompatibleProvider {
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
  /// The server's `Retry-After` hint as a `Duration`, honoring the millisecond form some routes send
  /// before falling back to whole/fractional seconds. The wait itself clamps this hint, so the raw
  /// value is returned here without a ceiling of its own.
  func retryAfterDelay(from result: HTTPResult) -> Duration? {
    if let milliseconds = result.getHeader(for: "retry-after-ms").flatMap(Double.init) {
      return .milliseconds(milliseconds)
    }
    return result.getHeader(for: "retry-after").flatMap(Double.init).map { .seconds($0) }
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
