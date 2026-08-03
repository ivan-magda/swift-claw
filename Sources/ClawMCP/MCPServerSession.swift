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
/// Every call is bounded by the server's worst case (connect plus request), which is the budget
/// `Tool.timeout` is sized from. The HTTP timeouts bound each exchange; this bounds the chain, so a
/// server that answers with something the SDK never matches to our request cannot park a caller
/// forever.
public actor MCPServerSession {
  nonisolated public let config: MCPServerConfig

  private let factory: any MCPTransportFactory
  private let clientVersion: String
  private let logger: Logger
  private let encoder = JSONEncoder()

  private var client: Client?
  /// The in-flight connect, shared by every caller that arrives during it. An actor does not
  /// serialize across `await`, so without this two concurrent calls would each open a session.
  private var opening: Task<Client, any Error>?

  public init(
    config: MCPServerConfig,
    transportFactory: any MCPTransportFactory,
    clientVersion: String,
    logger: Logger = Logger(label: "claw.mcp.session")
  ) {
    self.config = config
    self.factory = transportFactory
    self.clientVersion = clientVersion
    self.logger = logger
  }

  /// Performs the initialize handshake if one is not already live. The transport bounds it by the
  /// server's `connectTimeoutSeconds`.
  public func connect() async throws {
    _ = try await connected()
  }

  /// The server's whole tool list, paged under the discovery caps.
  public func listAllTools() async throws -> [MCP.Tool] {
    let client = try await connected()

    var discovered: [MCP.Tool] = []
    var replayed: Set<String> = []
    var bytes = 0
    var cursor: String?
    var page = 0

    while true {
      guard page < MCPDiscoveryLimits.maxPages else {
        throw MCPSessionError.tooManyPages(limit: MCPDiscoveryLimits.maxPages)
      }
      let listing = try await client.listTools(cursor: cursor)
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

    let race = await DeadlineRace.race(allowance: .seconds(budget)) {
      do {
        return Attempt.completed(try await self.attempt(name: name, arguments: payload))
      } catch {
        return Attempt.failed(error)
      }
    }

    switch race {
    case .operationReturned(.completed(let result)):
      return result
    case .operationReturned(.failed(let error)):
      throw error
    case .deadlineExpired:
      throw MCPSessionError.callTimedOut(seconds: budget)
    case .callerCancelled:
      throw CancellationError()
    }
  }

  /// Ends the session. The next call opens a fresh one.
  public func disconnect() async {
    await teardown()
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

    do {
      let result = try await client.connect(transport: transport)
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
  enum Attempt: Sendable {
    case completed(MCPToolCallResult)
    case failed(any Error)
  }

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
