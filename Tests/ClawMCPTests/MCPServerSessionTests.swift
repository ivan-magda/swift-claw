import ClawCore
import Foundation
import MCP
import Testing

@testable import ClawMCP

@Suite("MCP server session")
struct MCPServerSessionTests {
  @Test("the whole tool list is paged in")
  func listsEveryPage() async throws {
    // given
    let scripted = ScriptedMCPServer(
      list: ScriptedMCPServer.paged([
        [ScriptedMCPServer.tool("first"), ScriptedMCPServer.tool("second")],
        [ScriptedMCPServer.tool("third")],
      ])
    )
    let session = try SessionFixture.session(against: scripted)

    // when
    let tools = try await session.listAllTools()

    // then
    #expect(tools.map(\.name) == ["first", "second", "third"])
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a server that pages forever is refused at the page cap")
  func pageCap() async throws {
    // given
    let scripted = ScriptedMCPServer(
      list: { parameters in
        let page = parameters.cursor.flatMap { cursor in
          Int(cursor)
        }
        return ListTools.Result(
          tools: [ScriptedMCPServer.tool("page_\(page ?? 0)")],
          nextCursor: String((page ?? 0) + 1)
        )
      }
    )
    let session = try SessionFixture.session(against: scripted)

    // when / then
    await #expect(
      throws: MCPSessionError.tooManyPages(limit: MCPDiscoveryLimits.maxPages)
    ) {
      try await session.listAllTools()
    }
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a server that repeats a cursor is refused")
  func repeatedCursor() async throws {
    // given
    let scripted = ScriptedMCPServer(
      list: { _ in
        ListTools.Result(tools: [ScriptedMCPServer.tool("looping")], nextCursor: "same")
      }
    )
    let session = try SessionFixture.session(against: scripted)

    // when / then
    await #expect(throws: MCPSessionError.pagingStalled) {
      try await session.listAllTools()
    }
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a server offering more tools than the cap is refused")
  func toolCountCap() async throws {
    // given
    let flood = (0...MCPDiscoveryLimits.maxTools).map { index in
      ScriptedMCPServer.tool("tool_\(index)")
    }
    let scripted = ScriptedMCPServer(list: ScriptedMCPServer.paged([flood]))
    let session = try SessionFixture.session(against: scripted)

    // when / then
    await #expect(
      throws: MCPSessionError.tooManyTools(limit: MCPDiscoveryLimits.maxTools)
    ) {
      try await session.listAllTools()
    }
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a tool list heavier than the byte cap is refused")
  func catalogByteCap() async throws {
    // given
    let bloated = ScriptedMCPServer.tool(
      "bloated",
      description: String(repeating: "x", count: MCPDiscoveryLimits.maxCatalogBytes + 1)
    )
    let scripted = ScriptedMCPServer(list: ScriptedMCPServer.paged([[bloated]]))
    let session = try SessionFixture.session(against: scripted)

    // when / then
    await #expect(
      throws: MCPSessionError.catalogTooLarge(limitBytes: MCPDiscoveryLimits.maxCatalogBytes)
    ) {
      try await session.listAllTools()
    }
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a call carries its arguments in the server's own number vocabulary")
  func callBridgesArguments() async throws {
    // given
    let seen = ArgumentRecorder()
    let scripted = ScriptedMCPServer(
      list: ScriptedMCPServer.paged([[ScriptedMCPServer.tool("create_issue")]]),
      call: { _, parameters in
        await seen.record(parameters.arguments ?? [:])
        return CallTool.Result(content: [.text(text: "created", annotations: nil, _meta: nil)])
      }
    )
    let session = try SessionFixture.session(against: scripted)

    // when
    let result = try await session.callTool(
      name: "create_issue",
      arguments: ["title": .string("ship it"), "priority": .number(2), "ratio": .number(1.5)]
    )

    // then
    #expect(result.isError == false)
    #expect(result.content.count == 1)
    let arguments = await seen.arguments
    #expect(arguments["title"] == .string("ship it"))
    #expect(arguments["priority"] == .int(2))
    #expect(arguments["ratio"] == .double(1.5))
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a server-reported failure comes back as a result, not a throw")
  func serverReportedError() async throws {
    // given
    let scripted = ScriptedMCPServer(
      list: ScriptedMCPServer.paged([[ScriptedMCPServer.tool("failing")]]),
      call: { _, _ in
        CallTool.Result(
          content: [.text(text: "no such issue", annotations: nil, _meta: nil)],
          isError: true
        )
      }
    )
    let session = try SessionFixture.session(against: scripted)

    // when
    let result = try await session.callTool(name: "failing", arguments: [:])

    // then
    #expect(result.isError)
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a call that finds the session expired reconnects once and retries")
  func reconnectsOnExpiredSession() async throws {
    // given the first connection drops our session on the call that follows its handshake
    let scripted = ScriptedMCPServer(list: ScriptedMCPServer.paged([[]]))
    let session = try SessionFixture.session(
      against: scripted,
      transport: { transport, connection in
        guard connection == 1 else {
          return transport
        }
        return FaultyTransport(
          wrapping: transport,
          failingSend: FaultyTransport.firstCallSend,
          with: .sessionExpired
        )
      }
    )
    try await session.connect()

    // when
    let result = try await session.callTool(name: "list_issues", arguments: [:])

    // then the retry landed on a second connection
    #expect(await scripted.connections == 2)
    #expect(
      result.content == [.text(text: "list_issues on connection 2", annotations: nil, _meta: nil)]
    )
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a failure that may have executed is never retried")
  func doesNotRetryPossiblyExecutedCall() async throws {
    // given
    let scripted = ScriptedMCPServer(list: ScriptedMCPServer.paged([[]]))
    let session = try SessionFixture.session(
      against: scripted,
      transport: { transport, connection in
        guard connection == 1 else {
          return transport
        }
        return FaultyTransport(
          wrapping: transport,
          failingSend: FaultyTransport.firstCallSend,
          with: .httpStatus(500)
        )
      }
    )
    try await session.connect()

    // when / then
    await #expect(throws: MCPTransportError.httpStatus(500)) {
      try await session.callTool(name: "create_issue", arguments: [:])
    }
    #expect(await scripted.connections == 1)
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a call after the server restarted opens a fresh session")
  func callAfterRestart() async throws {
    // given
    let scripted = ScriptedMCPServer(list: ScriptedMCPServer.paged([[]]))
    let session = try SessionFixture.session(against: scripted)
    _ = try await session.callTool(name: "list_issues", arguments: [:])

    // when the server goes away and the session is dropped with it
    await scripted.stop()
    await session.disconnect()
    let result = try await session.callTool(name: "list_issues", arguments: [:])

    // then
    #expect(await scripted.connections == 2)
    #expect(
      result.content == [.text(text: "list_issues on connection 2", annotations: nil, _meta: nil)]
    )
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a server that never answers surfaces its connect failure")
  func unreachableServer() async throws {
    // given
    let refused = MCPTransportError.requestFailed(
      HTTPTransportFailure(disposition: .definitelyNotSent, safeMessage: "connection refused")
    )
    let session = MCPServerSession(
      config: try SessionFixture.config(),
      transportFactory: StubTransportFactory {
        throw refused
      },
      clientVersion: SessionFixture.clientVersion
    )

    // when / then
    await #expect(throws: refused) {
      try await session.connect()
    }
  }
}

// MARK: - Fixtures

private actor ArgumentRecorder {
  private(set) var arguments: [String: Value] = [:]

  func record(_ arguments: [String: Value]) {
    self.arguments = arguments
  }
}

private enum SessionFixture {
  static let clientVersion = "0.0.0-test"

  static func config(
    name: String = "linear",
    tools: MCPToolFilter = .allowAll
  ) throws -> MCPServerConfig {
    try MCPServerConfig(name: name, url: "https://mcp.example.com/mcp", tools: tools)
  }

  /// A session whose every connection is served by `scripted`, optionally wrapped per connection.
  static func session(
    against scripted: ScriptedMCPServer,
    config: MCPServerConfig? = nil,
    transport: (@Sendable (InMemoryTransport, Int) async -> any Transport)? = nil
  ) throws -> MCPServerSession {
    MCPServerSession(
      config: try config ?? SessionFixture.config(),
      transportFactory: StubTransportFactory {
        let opened = try await scripted.makeTransport()
        guard let transport else {
          return opened
        }
        return await transport(opened, await scripted.connections)
      },
      clientVersion: clientVersion
    )
  }

  static func tearDown(_ session: MCPServerSession, _ scripted: ScriptedMCPServer) async {
    await session.disconnect()
    await scripted.stop()
  }
}
