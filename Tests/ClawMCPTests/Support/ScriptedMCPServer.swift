import Foundation
import Logging
import MCP

@testable import ClawMCP

/// A real SDK server reachable over in-memory transports.
///
/// Every `makeTransport()` builds a fresh pair *and* a fresh `Server`, which is what a restart looks
/// like from the client side — so reconnect scenarios need no special support beyond counting how
/// many times a session came back.
actor ScriptedMCPServer {
  typealias ListHandler = @Sendable (ListTools.Parameters) async throws -> ListTools.Result
  typealias CallHandler = @Sendable (Int, CallTool.Parameters) async throws -> CallTool.Result

  private let name: String
  private let list: ListHandler
  private let call: CallHandler
  private var started: [Server] = []
  private(set) var connections = 0

  init(
    name: String = "fixture-server",
    list: @escaping ListHandler,
    call: @escaping CallHandler = ScriptedMCPServer.echo
  ) {
    self.name = name
    self.list = list
    self.call = call
  }

  /// The concrete type, not `any Transport`, so a test can wrap the client side before handing it
  /// to a session.
  func makeTransport() async throws -> InMemoryTransport {
    connections += 1
    let connection = connections

    let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
    let server = Server(
      name: name,
      version: "1.0.0",
      capabilities: Server.Capabilities(tools: Server.Capabilities.Tools(listChanged: false))
    )
    let list = self.list
    let call = self.call

    await server.withMethodHandler(ListTools.self) { parameters in
      try await list(parameters)
    }
    await server.withMethodHandler(CallTool.self) { parameters in
      try await call(connection, parameters)
    }
    try await server.start(transport: serverSide)
    started.append(server)

    return clientSide
  }

  func stop() async {
    for server in started {
      await server.stop()
    }
    started.removeAll()
  }

  /// Serves the given pages, using the page index as the cursor.
  static func paged(_ pages: [[MCP.Tool]]) -> ListHandler {
    { parameters in
      let index = parameters.cursor.flatMap { cursor in
        Int(cursor)
      }
      let page = index ?? 0
      guard page < pages.count else {
        return ListTools.Result(tools: [])
      }
      let next = page + 1 < pages.count ? String(page + 1) : nil

      return ListTools.Result(tools: pages[page], nextCursor: next)
    }
  }

  /// Names the connection it was served by, so a caller can tell which server instance answered.
  static let echo: CallHandler = { connection, parameters in
    CallTool.Result(
      content: [
        .text(text: "\(parameters.name) on connection \(connection)", annotations: nil, _meta: nil)
      ]
    )
  }

  static func tool(
    _ name: String,
    description: String = "a fixture tool",
    schema: Value = .object(["type": .string("object"), "properties": .object([:])])
  ) -> MCP.Tool {
    MCP.Tool(name: name, description: description, inputSchema: schema)
  }
}

/// Opens whatever the test scripts — a live transport, or a failure standing in for a server that
/// never answered.
struct StubTransportFactory: MCPTransportFactory {
  let open: @Sendable () async throws -> any Transport

  func makeTransport() async throws -> any Transport {
    try await open()
  }
}

/// Wraps a live transport and fails one `send`, which is how a server that dropped our session (or
/// answered with a status we cannot use) looks from inside the SDK client.
///
/// Sends are counted from the handshake: 1 is the initialize request, 2 the initialized
/// notification, and 3 the first request a caller makes.
actor FaultyTransport: Transport {
  static let firstCallSend = 3

  nonisolated let logger = Logger(label: "test.mcp.faulty")

  private let inner: InMemoryTransport
  private let failingSend: Int
  private let failure: MCPTransportError
  private var stream: AsyncThrowingStream<Data, any Error>?
  private var sends = 0

  init(wrapping inner: InMemoryTransport, failingSend: Int, with failure: MCPTransportError) {
    self.inner = inner
    self.failingSend = failingSend
    self.failure = failure
  }

  func connect() async throws {
    try await inner.connect()
    // Only after connecting: an in-memory transport hands out an already-finished stream while it
    // is still disconnected, and a finished stream ends the client's message loop before it starts.
    stream = await inner.receive()
  }

  func disconnect() async {
    await inner.disconnect()
  }

  func send(_ data: Data) async throws {
    sends += 1
    guard sends != failingSend else {
      throw failure
    }
    try await inner.send(data)
  }

  func receive() -> AsyncThrowingStream<Data, any Error> {
    stream
      ?? AsyncThrowingStream { continuation in
        continuation.finish()
      }
  }
}
