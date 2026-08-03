import ClawCore
import Foundation
import Logging
import MCP

/// Pinned bounds for one Streamable HTTP exchange, sized for a personal daemon talking to a handful
/// of servers. An implementer changing one changes it here.
public enum MCPTransportLimits {
  /// The most one JSON-RPC message may weigh: a whole JSON response, or a single SSE event still
  /// waiting for its blank line. A stream may run far longer than this — the bound is per message,
  /// not per transfer.
  public static let maxMessageBytes = 4 * 1024 * 1024
  /// Complete protocol messages waiting for the SDK's receive loop. The HTTP body channel has its
  /// own byte bound; this closes the second queue after framing has split that body into messages.
  public static let maxBufferedMessages = 16
  /// Cancellation is advisory and local continuation cleanup has already won. Do not let a server
  /// that ignores the notice consume another full request budget while the caller is timing out.
  public static let cancellationTimeout: Duration = .seconds(1)
}

/// The MCP Streamable HTTP transport, spoken over swift-claw's own HTTP seam.
///
/// The SDK ships one of these too, but it is built on URLSession and its SSE half is compiled out on
/// Linux — a daemon that runs on Linux cannot use it. Sitting on `HTTPExecuting & HTTPStreaming`
/// instead gives one HTTP road for the whole process (the same executor the LLM and Telegram clients
/// use) and puts the transport on a seam a test can script without a socket.
///
/// A POST carries one client message and its whole reply: the server chooses whether that reply
/// arrives as a single JSON document or as an event stream, and it says which only in the response
/// head — so every send opens a stream and branches there. `send` returns once that reply is
/// complete, which is what bounds a call by `requestTimeoutSeconds` rather than by the lifetime of
/// some background listener. There is no standalone GET channel: nothing in this client handles
/// server-initiated requests, so subscribing to them would only invite work we would drop.
///
/// The instance is single-use: `disconnect()` finishes the receive stream, and an `AsyncThrowingStream`
/// that has finished cannot be reopened. Reconnecting means building a new transport.
public actor MCPStreamableHTTPTransport: MCPNegotiatingTransport {
  nonisolated public let logger: Logger

  private let endpoint: String
  private var baseHeaders: [String: String]
  private let connectTimeout: Duration
  private let requestTimeout: Duration
  private let http: any HTTPExecuting & HTTPStreaming

  private var lifecycle: Lifecycle = .idle
  private var sessionID: String?
  /// Whether a reply has landed since `connect()`. Until one has, the exchange in flight is the
  /// initialize handshake, which is what `connectTimeoutSeconds` is there to bound.
  private var handshakeCompleted = false

  private let messages: AsyncThrowingStream<Data, any Error>
  private let messageContinuation: AsyncThrowingStream<Data, any Error>.Continuation

  public init(
    server: MCPServerConfig,
    token: String? = nil,
    http: any HTTPExecuting & HTTPStreaming,
    logger: Logger = Logger(label: "claw.mcp.transport")
  ) {
    self.endpoint = server.url.absoluteString
    self.baseHeaders = Self.baseHeaders(for: server, token: token)
    self.connectTimeout = .seconds(server.connectTimeoutSeconds)
    self.requestTimeout = .seconds(server.requestTimeoutSeconds)
    self.http = http
    self.logger = logger

    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(MCPTransportLimits.maxBufferedMessages)
    )
    self.messages = stream
    self.messageContinuation = continuation
  }

  /// Marks the transport usable. Streamable HTTP has no connection of its own — the initialize POST
  /// the SDK sends next is what reaches the server.
  public func connect() async throws {
    switch lifecycle {
    case .connected:
      return
    case .disconnected:
      throw MCPTransportError.notConnected
    case .idle:
      lifecycle = .connected
    }
  }

  /// Ends the receive stream, then tells the server the session is over. The order matters: the
  /// SDK's message loop is parked on our stream and is awaited by `Client.disconnect`, so finishing
  /// first means a slow teardown request cannot hold up a shutdown.
  public func disconnect() async {
    guard lifecycle == .connected else {
      return
    }
    lifecycle = .disconnected
    messageContinuation.finish()

    guard let session = sessionID else {
      return
    }
    sessionID = nil
    await deleteSession(session)
  }

  public func send(_ data: Data) async throws {
    guard lifecycle == .connected else {
      throw MCPTransportError.notConnected
    }

    let exchange = try await open(data)
    capture(from: exchange.head)

    do {
      try validate(exchange.head)
      try await deliver(exchange)
    } catch {
      _ = await exchange.cancelAndAwait()
      throw Self.mapped(error)
    }

    handshakeCompleted = true
  }

  public func receive() -> AsyncThrowingStream<Data, any Error> {
    messages
  }

  /// Switches every request after the handshake to the revision the server agreed to speak. Until
  /// one has been agreed the header carries our offer, which is the only thing there is to send.
  public func adopt(protocolVersion: String) {
    guard Version.supported.contains(protocolVersion) else {
      return
    }
    baseHeaders.setValue(protocolVersion, forHeader: MCPHTTPHeader.protocolVersion)
  }
}

// MARK: - Request shaping

private extension MCPStreamableHTTPTransport {
  enum Lifecycle {
    case idle
    case connected
    case disconnected
  }

  enum ContentType {
    static let json = "application/json"
    static let eventStream = "text/event-stream"
  }

  /// Every header that does not change between requests. The framing headers are set last on
  /// purpose: an owner's `headers` entry may add to the exchange, never redefine what it is.
  static func baseHeaders(for server: MCPServerConfig, token: String?) -> [String: String] {
    var headers = server.headers

    if let token, token.isEmpty == false {
      headers.setValue(server.authorizationValue(for: token), forHeader: server.authHeader)
    }

    headers.setValue(
      "\(ContentType.json), \(ContentType.eventStream)",
      forHeader: MCPHTTPHeader.accept
    )
    headers.setValue(ContentType.json, forHeader: MCPHTTPHeader.contentType)
    headers.setValue(MCPProtocol.version, forHeader: MCPHTTPHeader.protocolVersion)

    return headers
  }

  func outboundHeaders() -> [String: String] {
    guard let sessionID else {
      return baseHeaders
    }

    var headers = baseHeaders
    headers.setValue(sessionID, forHeader: MCPHTTPHeader.session)

    return headers
  }

  func open(_ body: Data) async throws -> HTTPStreamExchange {
    let request = HTTPRequest(
      method: .post,
      url: endpoint,
      headers: outboundHeaders(),
      body: body,
      timeout: exchangeTimeout(for: body),
      responseBodyPolicy: .streaming(
        maximumUnreadBytes: MCPTransportLimits.maxMessageBytes,
        errorBytes: HTTPResponseBodyPolicy.diagnosticBodyBytes
      )
    )

    do {
      return try await http.openStream(request)
    } catch {
      throw Self.mapped(error)
    }
  }

  func exchangeTimeout(for body: Data) -> Duration {
    guard handshakeCompleted else {
      return connectTimeout
    }
    guard
      let envelope = try? JSONDecoder().decode(OutboundMethodEnvelope.self, from: body),
      envelope.method == CancelledNotification.name
    else {
      return requestTimeout
    }
    return min(requestTimeout, MCPTransportLimits.cancellationTimeout)
  }

  struct OutboundMethodEnvelope: Decodable {
    let method: String?
  }

  /// Sends the spec's session teardown. Best effort by definition: the session is already gone as
  /// far as this process is concerned, and a server that refuses the DELETE cannot change that.
  func deleteSession(_ session: String) async {
    var headers = baseHeaders
    headers.setValue(session, forHeader: MCPHTTPHeader.session)

    let request = HTTPRequest(
      method: .delete,
      url: endpoint,
      headers: headers,
      body: nil,
      timeout: connectTimeout,
      responseBodyPolicy: .buffered(
        successBytes: HTTPResponseBodyPolicy.diagnosticBodyBytes,
        errorBytes: HTTPResponseBodyPolicy.diagnosticBodyBytes
      )
    )
    _ = try? await http.execute(request)
  }

  static func mapped(_ error: any Error) -> any Error {
    guard let failure = error as? HTTPTransportFailure else {
      return error
    }
    return MCPTransportError.requestFailed(failure)
  }
}

// MARK: - Response handling

private extension MCPStreamableHTTPTransport {
  func capture(from head: HTTPStreamHead) {
    guard
      let session = head.getHeader(for: MCPHTTPHeader.session),
      session.isEmpty == false
    else {
      return
    }
    sessionID = session
  }

  func validate(_ head: HTTPStreamHead) throws {
    guard HTTPResponseBodyPolicy.isSuccess(head.statusCode) == false else {
      return
    }
    // A 404 while we are replaying a session id is the spec's way of saying the server dropped that
    // session; without one it is an ordinary wrong-endpoint answer.
    guard head.statusCode == 404, sessionID != nil else {
      throw MCPTransportError.httpStatus(head.statusCode)
    }
    sessionID = nil
    throw MCPTransportError.sessionExpired
  }

  func deliver(_ exchange: HTTPStreamExchange) async throws {
    // 202 is the whole answer to a notification: accepted, nothing to reply with.
    guard exchange.head.statusCode != 202 else {
      _ = await exchange.cancelAndAwait()
      return
    }

    let rawContentType = exchange.head.getHeader(for: MCPHTTPHeader.contentType) ?? ""
    let contentType =
      rawContentType
      .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    if contentType == ContentType.eventStream {
      try await deliverEvents(exchange)
    } else if contentType == ContentType.json {
      try await deliverDocument(exchange)
    } else {
      throw MCPTransportError.unsupportedContentType(rawContentType.lowercased())
    }
  }

  func deliverDocument(_ exchange: HTTPStreamExchange) async throws {
    var body = Data()

    for try await chunk in exchange.body {
      body.append(chunk)
      guard body.count <= MCPTransportLimits.maxMessageBytes else {
        throw MCPTransportError.oversizedMessage(limitBytes: MCPTransportLimits.maxMessageBytes)
      }
    }
    try check(await exchange.awaitTermination())

    try yield(message: body)
  }

  func deliverEvents(_ exchange: HTTPStreamExchange) async throws {
    var buffer = Data()

    for try await chunk in exchange.body {
      buffer.append(chunk)

      while let delimiter = SSEFraming.delimiterRange(in: buffer) {
        let event = Data(buffer[..<delimiter.lowerBound])
        buffer.removeSubrange(..<delimiter.upperBound)
        try yield(event: event)
      }

      guard buffer.count <= MCPTransportLimits.maxMessageBytes else {
        throw MCPTransportError.oversizedMessage(limitBytes: MCPTransportLimits.maxMessageBytes)
      }
    }
    try check(await exchange.awaitTermination())

    // A server that closes right after its last `data:` line, without the blank line that would end
    // the event, still sent us a whole message. Reading it is what keeps such a server usable; a
    // genuinely truncated one only fails later, at decode, where it was going to fail anyway.
    try yield(event: buffer)
  }

  func yield(event raw: Data) throws {
    guard let text = String(data: raw, encoding: .utf8) else {
      return
    }
    let payload = SSEFraming.dataPayloadLines(in: text).joined(separator: "\n")
    try yield(message: Data(payload.utf8))
  }

  func yield(message: Data) throws {
    guard message.isEmpty == false else {
      return
    }
    adoptVersionFromHandshake(message)
    switch messageContinuation.yield(message) {
    case .enqueued:
      return
    case .dropped:
      let error = MCPTransportError.receiveBufferOverflow(
        limitMessages: MCPTransportLimits.maxBufferedMessages
      )
      messageContinuation.finish(throwing: error)
      throw error
    case .terminated:
      throw MCPTransportError.notConnected
    @unknown default:
      throw MCPTransportError.notConnected
    }
  }

  /// `Client.connect` sends `notifications/initialized` before it returns its result. The negotiated
  /// revision therefore has to reach the header here, before the initialize response is yielded to
  /// the SDK and unblocks that notification.
  func adoptVersionFromHandshake(_ message: Data) {
    guard handshakeCompleted == false,
      let envelope = try? JSONDecoder().decode(InitializeEnvelope.self, from: message),
      let version = envelope.result?.protocolVersion,
      Version.supported.contains(version)
    else {
      return
    }
    baseHeaders.setValue(version, forHeader: MCPHTTPHeader.protocolVersion)
  }

  struct InitializeEnvelope: Decodable {
    struct Result: Decodable {
      let protocolVersion: String
    }

    let result: Result?
  }

  func check(_ termination: HTTPStreamTermination) throws {
    switch termination {
    case .completed:
      return
    case .failed(let failure):
      throw MCPTransportError.requestFailed(failure)
    case .cancelled(let disposition):
      throw MCPTransportError.requestFailed(
        HTTPTransportFailure(disposition: disposition, safeMessage: "response stream ended early")
      )
    }
  }
}

// MARK: - Header merging

private extension Dictionary where Key == String, Value == String {
  /// Sets `name`, dropping any entry that differs only in case — two spellings of one header name
  /// would otherwise both reach the wire.
  mutating func setValue(_ value: String, forHeader name: String) {
    for existing in keys where existing.caseInsensitiveCompare(name) == .orderedSame {
      removeValue(forKey: existing)
    }
    self[name] = value
  }
}
