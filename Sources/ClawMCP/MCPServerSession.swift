import ClawCore
import Foundation
import Logging
import MCP

/// Pinned bounds on what one server may contribute at discovery, sized for a personal daemon.
/// An implementer changing one changes it here.
public enum MCPDiscoveryLimits {
  public static let maxPages = 16
  public static let maxTools = 512
  public static let maxCatalogBytes = 2 * 1024 * 1024
  /// How many servers are contacted at once. Discovery order stays config order regardless.
  public static let connectConcurrency = 4
}

/// Builds the transport a session speaks over.
///
/// Our Streamable HTTP transport is single-use — `disconnect()` finishes its receive stream, and a
/// finished `AsyncThrowingStream` cannot reopen — so reconnecting means building a new one. Making
/// that a seam is also what lets the session suites run a real client against a real SDK server
/// with no socket in between.
public protocol MCPTransportFactory: Sendable {
  func makeTransport() async throws -> any Transport
}

/// A transport that names the protocol revision on the wire, and so has to be told which one the
/// handshake actually settled on.
///
/// The SDK offers the newest revision it knows and the server answers with the one it will speak. A
/// client that keeps announcing the offer rather than the answer is telling a server pinned to an
/// older revision that it is about to receive something it never agreed to, which the spec lets that
/// server refuse outright. The SDK updates only its own HTTP transport, so ours declares this.
public protocol MCPNegotiatingTransport: Transport {
  func adopt(protocolVersion: String) async
}

/// The production factory: one Streamable HTTP transport per connection, over the shared HTTP seam.
public struct MCPStreamableHTTPTransportFactory: MCPTransportFactory {
  private let server: MCPServerConfig
  private let token: String?
  private let http: any HTTPExecuting & HTTPStreaming
  private let logger: Logger

  public init(
    server: MCPServerConfig,
    token: String?,
    http: any HTTPExecuting & HTTPStreaming,
    logger: Logger = Logger(label: "claw.mcp.transport")
  ) {
    self.server = server
    self.token = token
    self.http = http
    self.logger = logger
  }

  public func makeTransport() async throws -> any Transport {
    MCPStreamableHTTPTransport(server: server, token: token, http: http, logger: logger)
  }
}

/// What one remote tool call returned. The content stays in the SDK's vocabulary — rendering it
/// into a tool payload is the adapter's job, not the session's.
public struct MCPToolCallResult: Sendable {
  public let content: [MCP.Tool.Content]
  public let structuredContent: JSONValue?
  /// The server's own report that the call failed, which is a result, not a transport failure.
  public let isError: Bool

  public init(
    content: [MCP.Tool.Content],
    structuredContent: JSONValue? = nil,
    isError: Bool
  ) {
    self.content = content
    self.structuredContent = structuredContent
    self.isError = isError
  }
}

/// One owner-configured MCP server, and the live client talking to it.
///
/// The session owns the connection lifecycle so its callers never see one: `listAllTools` and
/// `callTool` connect on demand, and a call that finds the session gone reconnects once and retries
/// — but only when the failure proves the call never ran, since a remote tool is a side effect and
/// retrying a maybe-executed one would run it twice.
///
/// The handshake and each ordinary request keep their configured budgets; a tool call additionally
/// gets the combined connect-plus-request budget because it may reconnect once. The HTTP timeouts
/// bound each transfer, while these bounds also cover a server that sends no matching JSON-RPC id.
public actor MCPServerSession {
  nonisolated public let config: MCPServerConfig

  private let factory: any MCPTransportFactory
  private let clientVersion: String
  private let logger: Logger
  private let connectAllowance: Duration
  private let requestAllowance: Duration
  private let callAllowance: Duration
  private let encoder = JSONEncoder()

  private var client: Client?
  /// The in-flight connect, shared by every caller that arrives during it. An actor does not
  /// serialize across `await`, so without this two concurrent calls would each open a session.
  private var opening: Task<Client, any Error>?

  public init(
    config: MCPServerConfig,
    transportFactory: any MCPTransportFactory,
    clientVersion: String,
    logger: Logger = Logger(label: "claw.mcp.session"),
    connectAllowance: Duration? = nil,
    requestAllowance: Duration? = nil,
    callAllowance: Duration? = nil
  ) {
    self.config = config
    self.factory = transportFactory
    self.clientVersion = clientVersion
    self.logger = logger
    self.connectAllowance = connectAllowance ?? .seconds(config.connectTimeoutSeconds)
    self.requestAllowance = requestAllowance ?? .seconds(config.requestTimeoutSeconds)
    self.callAllowance = callAllowance ?? .seconds(config.worstCaseCallSeconds)
  }

  /// Performs the initialize handshake if one is not already live.
  public func connect() async throws {
    _ = try await connected()
  }

  /// The server's whole tool list, paged under the discovery caps.
  public func listAllTools() async throws -> [MCP.Tool] {
    let client = try await connected()
    let budget = config.requestTimeoutSeconds

    var discovered: [MCP.Tool] = []
    var replayed: Set<String> = []
    var bytes = 0
    var cursor: String?
    var page = 0

    while true {
      guard page < MCPDiscoveryLimits.maxPages else {
        throw MCPSessionError.tooManyPages(limit: MCPDiscoveryLimits.maxPages)
      }
      let requested = cursor
      let request =
        requested.map { cursor in
          ListTools.request(.init(cursor: cursor))
        } ?? ListTools.request(.init())
      let cancellation = MCPRequestCancellation()
      let context: RequestContext<ListTools.Result> = try await client.send(request)
      await cancellation.track(client: client, requestID: context.requestID)
      let listing = try await bounded(
        allowance: requestAllowance,
        timingOutWith: .discoveryTimedOut(seconds: budget),
        cancellation: cancellation
      ) {
        try await context.value
      }
      await cancellation.clear(requestID: context.requestID)
      page += 1

      discovered.append(contentsOf: listing.tools)
      guard discovered.count <= MCPDiscoveryLimits.maxTools else {
        throw MCPSessionError.tooManyTools(limit: MCPDiscoveryLimits.maxTools)
      }
      bytes += try encoder.encode(listing.tools).count
      guard bytes <= MCPDiscoveryLimits.maxCatalogBytes else {
        throw MCPSessionError.catalogTooLarge(limitBytes: MCPDiscoveryLimits.maxCatalogBytes)
      }

      guard let next = listing.nextCursor, next.isEmpty == false else {
        return discovered
      }
      guard replayed.insert(next).inserted else {
        throw MCPSessionError.pagingStalled
      }
      cursor = next
    }
  }

  public func callTool(
    name: String,
    arguments: [String: JSONValue]
  ) async throws -> MCPToolCallResult {
    let payload = arguments.mapValues(MCPValueBridge.value)
    let budget = config.worstCaseCallSeconds

    let cancellation = MCPRequestCancellation()
    return try await bounded(
      allowance: callAllowance,
      timingOutWith: .callTimedOut(seconds: budget),
      cancellation: cancellation
    ) {
      try await self.attempt(name: name, arguments: payload, cancellation: cancellation)
    }
  }

  /// Ends the session. The next call opens a fresh one.
  public func disconnect() async {
    await teardown()
  }
}

/// Where a bounded operation leaves its result for the caller to collect.
///
/// It exists so the deadline race runs for `Void`: a generic result threaded through the race is
/// returned indirectly through the task allocator, which the runtime traps on here.
private actor BoundedSlot<Value: Sendable> {
  private enum Outcome {
    /// The operation lost the race, so it never reached either branch below.
    case pending
    case completed(Value)
    case failed(any Error)
  }

  private var outcome: Outcome = .pending

  func run(_ operation: @Sendable () async throws -> Value) async {
    do {
      outcome = .completed(try await operation())
    } catch {
      outcome = .failed(error)
    }
  }

  func resolve(orTimingOutWith timeout: MCPSessionError) throws -> Value {
    switch outcome {
    case .completed(let value):
      return value
    case .failed(let error):
      throw error
    case .pending:
      throw timeout
    }
  }
}

/// The SDK stores request continuations outside the caller task, so cancelling only the task leaves
/// them pending. Tracking the request id lets every deadline use the SDK's explicit cancellation path.
private actor MCPRequestCancellation {
  private var pending: (client: Client, requestID: ID)?
  private var cancelled = false

  func track(client: Client, requestID: ID) async {
    guard cancelled == false else {
      try? await client.cancelRequest(requestID, reason: "swift-claw deadline")
      return
    }
    pending = (client, requestID)
  }

  func clear(requestID: ID) {
    guard pending?.requestID == requestID else {
      return
    }
    pending = nil
  }

  func cancel() async {
    cancelled = true
    guard let pending else {
      return
    }
    self.pending = nil
    try? await pending.client.cancelRequest(pending.requestID, reason: "swift-claw deadline")
  }
}

// MARK: - Budget

private extension MCPServerSession {
  /// Runs one exchange under the server's whole-chain budget.
  ///
  /// The HTTP timeouts bound each request and response, which is not the same guarantee: the SDK
  /// resolves a request only when a reply carrying its id arrives, so a server that finishes an
  /// exchange without ever sending that reply — a 202, an empty body, a stream of comments — leaves
  /// a caller waiting on something no timeout will ever fire on. Discovery runs at boot, so that
  /// caller would be the whole daemon.
  func bounded<Value: Sendable>(
    allowance: Duration,
    timingOutWith timeout: MCPSessionError,
    cancellation: MCPRequestCancellation? = nil,
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let slot = BoundedSlot<Value>()
    let race = await DeadlineRace.race(allowance: allowance) {
      await slot.run(operation)
    }

    switch race {
    case .operationReturned:
      return try await slot.resolve(orTimingOutWith: timeout)
    case .deadlineExpired:
      await cancellation?.cancel()
      throw timeout
    case .callerCancelled:
      await cancellation?.cancel()
      throw CancellationError()
    }
  }
}

// MARK: - Connection lifecycle

private extension MCPServerSession {
  func connected() async throws -> Client {
    if let client {
      return client
    }
    if let opening {
      return try await opening.value
    }

    let attempt = Task {
      try await self.open()
    }
    opening = attempt
    defer { opening = nil }

    let opened = try await attempt.value
    client = opened

    return opened
  }

  func open() async throws -> Client {
    let transport = try await factory.makeTransport()
    let client = Client(name: MCPProtocol.clientName, version: clientVersion)
    let budget = config.connectTimeoutSeconds

    do {
      let result = try await bounded(
        allowance: connectAllowance,
        timingOutWith: .discoveryTimedOut(seconds: budget)
      ) {
        try await client.connect(transport: transport)
      }
      if let negotiating = transport as? any MCPNegotiatingTransport {
        await negotiating.adopt(protocolVersion: result.protocolVersion)
      }
      logger.debug(
        "MCP session established",
        metadata: [
          "server": .string(config.name),
          "protocol": .string(result.protocolVersion),
        ]
      )
      return client
    } catch {
      // The client already owns the transport at this point; only it can close both.
      await client.disconnect()
      throw error
    }
  }

  func teardown() async {
    guard let live = client else {
      return
    }
    client = nil
    await live.disconnect()
  }
}

// MARK: - Calling

private extension MCPServerSession {
  func attempt(
    name: String,
    arguments: [String: Value],
    cancellation: MCPRequestCancellation
  ) async throws -> MCPToolCallResult {
    do {
      return try await invoke(name: name, arguments: arguments, cancellation: cancellation)
    } catch {
      guard Self.isSpentSession(error) else {
        throw error
      }
      await teardown()
      return try await invoke(name: name, arguments: arguments, cancellation: cancellation)
    }
  }

  func invoke(
    name: String,
    arguments: [String: Value],
    cancellation: MCPRequestCancellation
  ) async throws -> MCPToolCallResult {
    let client = try await connected()
    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: name,
      arguments: arguments
    )
    await cancellation.track(client: client, requestID: context.requestID)

    let result = try await bounded(
      allowance: requestAllowance,
      timingOutWith: .callTimedOut(seconds: config.requestTimeoutSeconds),
      cancellation: cancellation
    ) {
      try await context.value
    }
    await cancellation.clear(requestID: context.requestID)

    return MCPToolCallResult(
      content: result.content,
      structuredContent: result.structuredContent.map(MCPValueBridge.jsonValue),
      isError: result.isError ?? false
    )
  }

  /// Whether the failure says the session is gone *and* the call provably never ran. Anything that
  /// might have reached the tool is not retried: a second attempt would be a second side effect.
  static func isSpentSession(_ error: any Error) -> Bool {
    guard let failure = error as? MCPTransportError else {
      return false
    }

    switch failure {
    case .notConnected:
      return true
    case .sessionExpired:
      // The server rejected us at session lookup, before any tool could run.
      return true
    case .requestFailed(let transport):
      return transport.disposition == .definitelyNotSent
    case .httpStatus, .unsupportedContentType, .oversizedMessage, .receiveBufferOverflow:
      return false
    }
  }
}
