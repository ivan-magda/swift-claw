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
  /// The server's own report that the call failed, which is a result, not a transport failure.
  public let isError: Bool

  public init(content: [MCP.Tool.Content], isError: Bool) {
    self.content = content
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
/// Every exchange — the handshake and each tool-list page as much as a call — is bounded by the
/// server's worst case (connect plus request), which is the budget `Tool.timeout` is sized from. The
/// HTTP timeouts bound each request; this bounds the chain, so a server that answers with something
/// the SDK never matches to our request cannot park a caller forever.
public actor MCPServerSession {
  nonisolated public let config: MCPServerConfig

  private let factory: any MCPTransportFactory
  private let clientVersion: String
  private let logger: Logger
  private let allowance: Duration
  private let encoder = JSONEncoder()

  private var client: Client?
  /// The in-flight connect, shared by every caller that arrives during it. An actor does not
  /// serialize across `await`, so without this two concurrent calls would each open a session.
  private var opening: Task<Client, any Error>?

  /// - Parameter allowance: What one exchange gets before it is given up on. Defaults to the
  ///   server's own worst case, which is the only value production has any business using.
  public init(
    config: MCPServerConfig,
    transportFactory: any MCPTransportFactory,
    clientVersion: String,
    logger: Logger = Logger(label: "claw.mcp.session"),
    allowance: Duration? = nil
  ) {
    self.config = config
    self.factory = transportFactory
    self.clientVersion = clientVersion
    self.logger = logger
    self.allowance = allowance ?? .seconds(config.worstCaseCallSeconds)
  }

  /// Performs the initialize handshake if one is not already live.
  public func connect() async throws {
    _ = try await connected()
  }

  /// The server's whole tool list, paged under the discovery caps.
  public func listAllTools() async throws -> [MCP.Tool] {
    let client = try await connected()
    let budget = config.worstCaseCallSeconds

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
      let listing = try await bounded(timingOutWith: .discoveryTimedOut(seconds: budget)) {
        try await client.listTools(cursor: requested)
      }
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

    return try await bounded(timingOutWith: .callTimedOut(seconds: budget)) {
      try await self.attempt(name: name, arguments: payload)
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
    timingOutWith timeout: MCPSessionError,
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
      throw timeout
    case .callerCancelled:
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
    let budget = config.worstCaseCallSeconds

    do {
      let result = try await bounded(timingOutWith: .discoveryTimedOut(seconds: budget)) {
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
  func attempt(name: String, arguments: [String: Value]) async throws -> MCPToolCallResult {
    do {
      return try await invoke(name: name, arguments: arguments)
    } catch {
      guard Self.isSpentSession(error) else {
        throw error
      }
      await teardown()
      return try await invoke(name: name, arguments: arguments)
    }
  }

  func invoke(name: String, arguments: [String: Value]) async throws -> MCPToolCallResult {
    let client = try await connected()
    // The annotation picks the awaiting overload over the one returning a request context; the
    // optional is the SDK's own — a server that omits `isError` is not reporting a failure.
    // swiftlint:disable:next discouraged_optional_boolean
    let result: (content: [MCP.Tool.Content], isError: Bool?) = try await client.callTool(
      name: name,
      arguments: arguments
    )

    return MCPToolCallResult(content: result.content, isError: result.isError ?? false)
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
    case .httpStatus, .unsupportedContentType, .oversizedMessage:
      return false
    }
  }
}
