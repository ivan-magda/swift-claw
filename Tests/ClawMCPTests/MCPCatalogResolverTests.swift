import ClawCore
import Foundation
import MCP
import Testing

@testable import ClawMCP

@Suite("MCP catalog resolver")
struct MCPCatalogResolverTests {
  @Test("every enabled server contributes its tools, named and repaired, in config order")
  func catalogRoundTrip() async throws {
    // given
    let linear = ScriptedMCPServer(
      list: ScriptedMCPServer.paged([
        [
          MCP.Tool(
            name: "list issues",
            description: "lists issues",
            inputSchema: .object([
              "properties": .object(["team": .object(["type": .string("string")])]),
              "required": .array([.string("team"), .string("absent")]),
            ])
          )
        ]
      ])
    )
    let notion = ScriptedMCPServer(
      list: ScriptedMCPServer.paged([[ScriptedMCPServer.tool("read")]])
    )
    let sessions = [
      try CatalogFixture.session(named: "linear", against: linear),
      try CatalogFixture.session(named: "notion", against: notion),
    ]

    // when
    let catalog = await MCPCatalogResolver.resolve(sessions: sessions)

    // then
    #expect(catalog.tools.map(\.localName) == ["mcp__linear__list_issues", "mcp__notion__read"])
    #expect(
      catalog.outcomes == [
        MCPServerOutcome(server: "linear", status: .ok(toolCount: 1)),
        MCPServerOutcome(server: "notion", status: .ok(toolCount: 1)),
      ]
    )

    let resolved = try #require(catalog.tools.first)
    #expect(resolved.coordinate == MCPToolCoordinate(server: "linear", remoteName: "list issues"))
    #expect(resolved.description == "lists issues")
    #expect(resolved.riskLevel == .ask)
    // the schema arrives repaired: a missing `type`, and a `required` name with no property
    #expect(
      resolved.parameters
        == .object([
          "type": .string("object"),
          "properties": .object(["team": .object(["type": .string("string")])]),
          "required": .array([.string("team")]),
        ])
    )

    await CatalogFixture.tearDown(sessions, linear, notion)
  }

  @Test("a remote description longer than the cap is truncated")
  func descriptionCapped() async throws {
    // given
    let scripted = ScriptedMCPServer(
      list: ScriptedMCPServer.paged([
        [
          ScriptedMCPServer.tool(
            "verbose",
            description: String(repeating: "a", count: MCPDescriptionCap.maxGraphemes + 50)
          )
        ]
      ])
    )
    let sessions = [try CatalogFixture.session(named: "linear", against: scripted)]

    // when
    let catalog = await MCPCatalogResolver.resolve(sessions: sessions)

    // then
    let resolved = try #require(catalog.tools.first)
    #expect(resolved.description.count == MCPDescriptionCap.maxGraphemes)

    await CatalogFixture.tearDown(sessions, scripted)
  }

  @Test("an include list wins and exclude is ignored")
  func includeWins() async throws {
    // given
    let scripted = ScriptedMCPServer(
      list: ScriptedMCPServer.paged([
        [
          ScriptedMCPServer.tool("keep"),
          ScriptedMCPServer.tool("drop"),
          ScriptedMCPServer.tool("also_keep"),
        ]
      ])
    )
    let filter = MCPToolFilter(include: ["keep", "also_keep"], exclude: ["keep"])
    let sessions = [try CatalogFixture.session(named: "linear", against: scripted, tools: filter)]

    // when
    let catalog = await MCPCatalogResolver.resolve(sessions: sessions)

    // then
    #expect(catalog.tools.map(\.coordinate.remoteName) == ["keep", "also_keep"])
    #expect(catalog.outcomes == [MCPServerOutcome(server: "linear", status: .ok(toolCount: 2))])

    await CatalogFixture.tearDown(sessions, scripted)
  }

  @Test("an exclude list drops only the named tools")
  func excludeFilters() async throws {
    // given
    let scripted = ScriptedMCPServer(
      list: ScriptedMCPServer.paged([
        [ScriptedMCPServer.tool("keep"), ScriptedMCPServer.tool("drop")]
      ])
    )
    let filter = MCPToolFilter(exclude: ["drop"])
    let sessions = [try CatalogFixture.session(named: "linear", against: scripted, tools: filter)]

    // when
    let catalog = await MCPCatalogResolver.resolve(sessions: sessions)

    // then
    #expect(catalog.tools.map(\.coordinate.remoteName) == ["keep"])

    await CatalogFixture.tearDown(sessions, scripted)
  }

  @Test("an owner downgrade lands on the named tool only")
  func riskOverride() async throws {
    // given
    let scripted = ScriptedMCPServer(
      list: ScriptedMCPServer.paged([
        [ScriptedMCPServer.tool("read_only"), ScriptedMCPServer.tool("write_thing")]
      ])
    )
    let filter = MCPToolFilter(risk: ["read_only": .safe])
    let sessions = [try CatalogFixture.session(named: "linear", against: scripted, tools: filter)]

    // when
    let catalog = await MCPCatalogResolver.resolve(sessions: sessions)

    // then
    #expect(catalog.tools.map(\.riskLevel) == [.safe, .ask])

    await CatalogFixture.tearDown(sessions, scripted)
  }

  @Test("an unreachable server is skipped with its reason, leaving the rest of the catalog intact")
  func unreachableServerSkipped() async throws {
    // given
    let reachable = ScriptedMCPServer(
      list: ScriptedMCPServer.paged([[ScriptedMCPServer.tool("read")]])
    )
    let sessions = [
      MCPServerSession(
        config: try CatalogFixture.config(named: "offline"),
        transportFactory: StubTransportFactory {
          throw MCPTransportError.requestFailed(
            HTTPTransportFailure(disposition: .definitelyNotSent, safeMessage: "connection refused")
          )
        },
        clientVersion: CatalogFixture.clientVersion
      ),
      try CatalogFixture.session(named: "notion", against: reachable),
    ]

    // when
    let catalog = await MCPCatalogResolver.resolve(sessions: sessions)

    // then
    #expect(catalog.tools.map(\.localName) == ["mcp__notion__read"])
    #expect(catalog.outcomes.map(\.server) == ["offline", "notion"])
    guard case .skipped(let reason) = catalog.outcomes[0].status else {
      Issue.record("expected the offline server to be skipped")
      return
    }
    #expect(reason.contains("connection refused"))

    await CatalogFixture.tearDown(sessions, reachable)
  }

  @Test("a server that blows a discovery cap is skipped, not fatal")
  func oversizedServerSkipped() async throws {
    // given a server that pages without end
    let endless = ScriptedMCPServer(
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
    let sessions = [try CatalogFixture.session(named: "endless", against: endless)]

    // when
    let catalog = await MCPCatalogResolver.resolve(sessions: sessions)

    // then
    #expect(catalog.tools.isEmpty)
    #expect(
      catalog.outcomes == [
        MCPServerOutcome(
          server: "endless",
          status: .skipped(
            reason: "\(MCPSessionError.tooManyPages(limit: MCPDiscoveryLimits.maxPages))"
          )
        )
      ]
    )

    await CatalogFixture.tearDown(sessions, endless)
  }

  @Test("more servers than the connect window still resolve in config order")
  func boundedConcurrencyKeepsOrder() async throws {
    // given twice as many servers as run at once
    let count = MCPDiscoveryLimits.connectConcurrency * 2 + 1
    let scripted = (0..<count).map { index in
      ScriptedMCPServer(list: ScriptedMCPServer.paged([[ScriptedMCPServer.tool("tool_\(index)")]]))
    }
    let sessions = try scripted.enumerated().map { index, server in
      try CatalogFixture.session(named: "server_\(index)", against: server)
    }

    // when
    let catalog = await MCPCatalogResolver.resolve(sessions: sessions)

    // then
    #expect(
      catalog.tools.map(\.localName)
        == (0..<count).map { index in
          "mcp__server_\(index)__tool_\(index)"
        }
    )
    #expect(catalog.outcomes.map(\.server) == (0..<count).map { index in "server_\(index)" })

    for session in sessions {
      await session.disconnect()
    }
    for server in scripted {
      await server.stop()
    }
  }
}

// MARK: - Fixtures

private enum CatalogFixture {
  static let clientVersion = "0.0.0-test"

  static func config(
    named name: String,
    tools: MCPToolFilter = .allowAll
  ) throws -> MCPServerConfig {
    try MCPServerConfig(name: name, url: "https://mcp.example.com/mcp", tools: tools)
  }

  static func session(
    named name: String,
    against scripted: ScriptedMCPServer,
    tools: MCPToolFilter = .allowAll
  ) throws -> MCPServerSession {
    MCPServerSession(
      config: try config(named: name, tools: tools),
      transportFactory: StubTransportFactory {
        try await scripted.makeTransport()
      },
      clientVersion: clientVersion
    )
  }

  static func tearDown(_ sessions: [MCPServerSession], _ servers: ScriptedMCPServer...) async {
    for session in sessions {
      await session.disconnect()
    }
    for server in servers {
      await server.stop()
    }
  }
}
