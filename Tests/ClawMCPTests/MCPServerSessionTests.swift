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

  @Test("a handshake the server never answers gives up on the budget instead of parking the boot")
  func handshakeDeadline() async throws {
    // given a server that completes the exchange and sends no reply, so no HTTP timeout can fire
    let config = try SessionFixture.config()
    let session = MCPServerSession(
      config: config,
      transportFactory: StubTransportFactory {
        SilentTransport()
      },
      clientVersion: SessionFixture.clientVersion,
      connectAllowance: .zero
    )

    // when / then
    await #expect(
      throws: MCPSessionError.discoveryTimedOut(seconds: config.connectTimeoutSeconds)
    ) {
      try await session.connect()
    }
  }

  @Test("a tool list the server never answers gives up on the budget")
  func listDeadline() async throws {
    // given a server that answers the handshake and then goes quiet
    let config = try SessionFixture.config()
    let scripted = ScriptedMCPServer(list: ScriptedMCPServer.paged([[]]))
    let session = try SessionFixture.mutedAfterHandshake(against: scripted)
    try await session.connect()

    // when / then
    await #expect(
      throws: MCPSessionError.discoveryTimedOut(seconds: config.requestTimeoutSeconds)
    ) {
      try await session.listAllTools()
    }
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a call the server never answers gives up on the budget")
  func callDeadline() async throws {
    // given
    let config = try SessionFixture.config()
    let scripted = ScriptedMCPServer(list: ScriptedMCPServer.paged([[]]))
    let session = try SessionFixture.mutedAfterHandshake(against: scripted)
    try await session.connect()

    // when / then
    await #expect(
      throws: MCPSessionError.callTimedOut(seconds: config.worstCaseCallSeconds)
    ) {
      try await session.callTool(name: "create_issue", arguments: [:])
    }
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a timed-out request is explicitly cancelled in the SDK")
  func timeoutCancelsPendingSDKRequest() async throws {
    // given
    let scripted = ScriptedMCPServer(list: ScriptedMCPServer.paged([[]]))
    let transports = MutedTransportRecorder()
    let session = MCPServerSession(
      config: try SessionFixture.config(),
      transportFactory: StubTransportFactory {
        let opened = MuteAfterHandshakeTransport(
          wrapping: try await scripted.makeTransport(),
          mutingSend: FaultyTransport.firstCallSend
        )
        await transports.record(opened)
        return opened
      },
      clientVersion: SessionFixture.clientVersion,
      requestAllowance: SessionFixture.mutedAllowance
    )
    try await session.connect()

    // when
    _ = try? await session.listAllTools()

    // then
    let opened = try #require(await transports.last)
    #expect(await opened.methods.contains("notifications/cancelled"))

    await SessionFixture.tearDown(session, scripted)
  }

  @Test("a call that provably never left is retried; one that may have run is not")
  func retriesOnlyWhatNeverReachedTheTool() async throws {
    // given the same mid-call failure, differing only in whether it could have executed
    let cases: [(HTTPTransmissionDisposition, Int)] = [
      (.definitelyNotSent, 2),
      (.mayHaveBeenSent, 1),
    ]

    for (disposition, expectedConnections) in cases {
      let scripted = ScriptedMCPServer(list: ScriptedMCPServer.paged([[]]))
      let failure = MCPTransportError.requestFailed(
        HTTPTransportFailure(disposition: disposition, safeMessage: "call interrupted")
      )
      let session = try SessionFixture.session(
        against: scripted,
        transport: { transport, connection in
          guard connection == 1 else {
            return transport
          }
          return FaultyTransport(
            wrapping: transport,
            failingSend: FaultyTransport.firstCallSend,
            with: failure
          )
        }
      )
      try await session.connect()

      // when
      let result = try? await session.callTool(name: "create_issue", arguments: [:])

      // then a second side effect is never risked for the sake of one more attempt
      #expect(await scripted.connections == expectedConnections)
      #expect((result == nil) == (disposition == .mayHaveBeenSent))
      await SessionFixture.tearDown(session, scripted)
    }
  }

  @Test("concurrent callers share one handshake")
  func concurrentCallersShareOneConnect() async throws {
    // given
    let scripted = ScriptedMCPServer(list: ScriptedMCPServer.paged([[]]))
    let session = try SessionFixture.session(against: scripted)

    // when eight callers arrive with no session open
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          _ = try? await session.callTool(name: "list_issues", arguments: [:])
        }
      }
    }

    // then an actor not serializing across `await` did not turn into eight sessions
    #expect(await scripted.connections == 1)
    await SessionFixture.tearDown(session, scripted)
  }

  @Test("the session tells its transport which revision the handshake settled on")
  func adoptsNegotiatedVersion() async throws {
    // given
    let scripted = ScriptedMCPServer(list: ScriptedMCPServer.paged([[]]))
    let transports = TransportRecorder()
    let session = MCPServerSession(
      config: try SessionFixture.config(),
      transportFactory: StubTransportFactory {
        let opened = NegotiationRecordingTransport(wrapping: try await scripted.makeTransport())
        await transports.record(opened)
        return opened
      },
      clientVersion: SessionFixture.clientVersion
    )

    // when
    try await session.connect()

    // then the header on every request after the handshake names the answer, not our offer
    let opened = try #require(await transports.last)
    #expect(await opened.adopted == MCPProtocol.version)
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

private actor TransportRecorder {
  private(set) var last: NegotiationRecordingTransport?

  func record(_ transport: NegotiationRecordingTransport) {
    last = transport
  }
}

private actor MutedTransportRecorder {
  private(set) var last: MuteAfterHandshakeTransport?

  func record(_ transport: MuteAfterHandshakeTransport) {
    last = transport
  }
}

private enum SessionFixture {
  static let clientVersion = "0.0.0-test"

  /// A session against a server that answers the handshake and then never answers again. The
  /// allowance has to outlast an in-memory handshake and nothing else: what it bounds here is an
  /// exchange that would otherwise never end, so the deadline is the only way out either way.
  static let mutedAllowance = Duration.milliseconds(200)

  static func mutedAfterHandshake(
    against scripted: ScriptedMCPServer
  ) throws -> MCPServerSession {
    MCPServerSession(
      config: try config(),
      transportFactory: StubTransportFactory {
        MuteAfterHandshakeTransport(
          wrapping: try await scripted.makeTransport(),
          mutingSend: FaultyTransport.firstCallSend
        )
      },
      clientVersion: clientVersion,
      requestAllowance: mutedAllowance,
      callAllowance: mutedAllowance
    )
  }

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
