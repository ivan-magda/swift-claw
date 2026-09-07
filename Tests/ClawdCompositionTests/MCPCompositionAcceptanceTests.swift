import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawMCP
import ClawSecrets
import ClawTelegram
import ClawTestSupport
import ClawTools
import ClawWorkspace
import Foundation
import GRDB
import Logging
import Testing

@testable import clawd

/// The MCP acceptance layer: the composition functions the daemon boots through, driven directly.
///
/// It stops short of a full daemon boot on purpose — `DaemonRuntimeBundle` exposes no registry,
/// gate, or fingerprint, so a booted daemon could not be asked any of the questions below. What runs
/// here is otherwise production: the real Streamable HTTP transport, the real SDK client, the real
/// resolver and adapter, the real gate, and real in-memory GRDB stores.
@Suite struct MCPCompositionAcceptanceTests {
  // MARK: Catalog → registry

  @Test("resolved MCP tools follow the built-ins into the registry, at the ask tier")
  func mcpToolsFollowTheBuiltIns() async throws {
    // given
    let server = ScriptedMCPHTTPServer(
      tools: [RemoteTool(name: "list_issues"), RemoteTool(name: "create_issue")]
    )
    let builder = try makeBuilder(http: server, servers: [try serverConfig()])

    // when
    let stack = await builder.resolveMCPStack()
    let dispatcher = try makeDispatcher(builder, mcpTools: stack.tools)

    // then
    let names = dispatcher.definitions.map(\.name)
    #expect(
      names.prefix(5) == ["file_read", "file_write", "memory_write", "skill_load", "web_fetch"]
    )
    #expect(names.suffix(2) == ["mcp__linear__list_issues", "mcp__linear__create_issue"])

    let remote = try #require(dispatcher.definitions.first { $0.name.hasPrefix("mcp__") })
    #expect(remote.riskLevel == .ask)
    #expect(remote.egressClass == .arbitraryDestination)
  }

  @Test("an owner risk downgrade reaches the registered definition")
  func riskOverrideReachesTheDefinition() async throws {
    // given
    let server = ScriptedMCPHTTPServer(tools: [RemoteTool(name: "list_issues")])
    let builder = try makeBuilder(
      http: server,
      servers: [try serverConfig(tools: MCPToolFilter(risk: ["list_issues": .safe]))]
    )

    // when
    let stack = await builder.resolveMCPStack()
    let dispatcher = try makeDispatcher(builder, mcpTools: stack.tools)

    // then
    let remote = try #require(
      dispatcher.definitions.first { $0.name == "mcp__linear__list_issues" }
    )
    #expect(remote.riskLevel == .safe)
    #expect(remote.egressClass == .arbitraryDestination)
  }

  @Test("MCP credentials are redacted from provider-facing catalog metadata")
  func remoteMetadataIsRedactedWithTheBootUnion() async throws {
    // given the credential appears in every metadata position a hostile server controls
    let secret = "linear-token"
    let server = ScriptedMCPHTTPServer(
      tools: [
        RemoteTool(
          name: "search_\(secret)",
          description: "uses \(secret)",
          schemaJSON:
            #"{"type":"object","properties":{"linear-token":{"description":"linear-token"}}}"#
        )
      ]
    )
    let builder = try makeBuilder(
      http: server,
      servers: [try serverConfig()],
      credentials: ["linear": .token(secret)]
    )

    // when
    let stack = await builder.resolveMCPStack()
    let dispatcher = try makeDispatcher(builder, mcpTools: stack.tools)

    // then
    let definition = try #require(dispatcher.definitions.first { $0.name.hasPrefix("mcp__") })
    let parameters = try #require(CanonicalJSON.encode(definition.parameters))
    let providerSurface = definition.name + definition.description + parameters
    #expect(providerSurface.contains(secret) == false)
    #expect(providerSurface.contains(SecretRedactor.replacement))
  }

  @Test("a server that contributes no tool still leaves a session for shutdown to hang up")
  func zeroToolServerStillYieldsASession() async throws {
    // given a server whose whole catalog is filtered away, so no adapter holds its session
    let server = ScriptedMCPHTTPServer(tools: [RemoteTool(name: "create_issue")])
    let builder = try makeBuilder(
      http: server,
      servers: [try serverConfig(tools: MCPToolFilter(include: ["nothing_matches"]))]
    )

    // when
    let stack = await builder.resolveMCPStack()

    // then
    #expect(stack.tools.isEmpty)
    #expect(stack.sessions.count == 1)
  }

  // MARK: Policy fingerprint

  @Test("the policy sub-hash is stable across resolutions and moves when the catalog does")
  func policySubhashPinsTheCatalog() async throws {
    // given
    let tools = [RemoteTool(name: "list_issues")]
    let servers = [try serverConfig()]
    // One state root across all three, so the catalog is the only input that can move the hash.
    let config = try CompositionAcceptance.chatGPTConfig()

    // when
    let first = try await subhash(ScriptedMCPHTTPServer(tools: tools), config, servers)
    let repeated = try await subhash(ScriptedMCPHTTPServer(tools: tools), config, servers)
    let widened = try await subhash(
      ScriptedMCPHTTPServer(tools: tools + [RemoteTool(name: "create_issue")]),
      config,
      servers
    )

    // then
    #expect(first == repeated)
    #expect(first != widened)
  }

  @Test("the policy sub-hash moves when an MCP endpoint changes")
  func policySubhashPinsTheEndpoint() async throws {
    // given
    let tools = [RemoteTool(name: "list_issues")]
    let config = try CompositionAcceptance.chatGPTConfig()

    // when
    let first = try await subhash(
      ScriptedMCPHTTPServer(tools: tools),
      config,
      [try serverConfig(url: "https://mcp.test.invalid/one")]
    )
    let moved = try await subhash(
      ScriptedMCPHTTPServer(tools: tools),
      config,
      [try serverConfig(url: "https://mcp.test.invalid/two")]
    )

    // then
    #expect(first != moved)
  }

  @Test("the policy sub-hash pins MCP static headers by HTTP semantics")
  func policySubhashPinsRequestContext() async throws {
    // given
    let tools = [RemoteTool(name: "list_issues")]
    let config = try CompositionAcceptance.chatGPTConfig()

    // when
    let first = try await subhash(
      ScriptedMCPHTTPServer(tools: tools),
      config,
      [
        try serverConfig(
          headers: ["X-Workspace": "alpha"],
          authHeader: "X-API-Key"
        )
      ]
    )
    let caseOnlyChange = try await subhash(
      ScriptedMCPHTTPServer(tools: tools),
      config,
      [
        try serverConfig(
          headers: ["x-workspace": "alpha"],
          authHeader: "x-api-key"
        )
      ]
    )
    let movedWorkspace = try await subhash(
      ScriptedMCPHTTPServer(tools: tools),
      config,
      [
        try serverConfig(
          headers: ["X-Workspace": "beta"],
          authHeader: "X-API-Key"
        )
      ]
    )
    let movedAuthentication = try await subhash(
      ScriptedMCPHTTPServer(tools: tools),
      config,
      [
        try serverConfig(
          headers: ["X-Workspace": "alpha"],
          authHeader: "X-Auth-Token"
        )
      ]
    )

    // then
    #expect(first == caseOnlyChange)
    #expect(first != movedWorkspace)
    #expect(first != movedAuthentication)
  }

  // MARK: Ask-tier round trip

  @Test("an ask-tier MCP call parks, then executes as untrusted through the approved path")
  func askTierCallParksThenExecutesUntrusted() async throws {
    // given
    let server = ScriptedMCPHTTPServer(
      tools: [RemoteTool(name: "list_issues")],
      outcome: .text("ISSUE-1: the roof leaks")
    )
    let builder = try makeBuilder(http: server, servers: [try serverConfig()])
    let dispatcher = try makeDispatcher(
      builder,
      mcpTools: await builder.resolveMCPStack().tools
    )
    let call = ToolCall(
      id: "c1",
      name: "mcp__linear__list_issues",
      argumentsJSON: #"{"query":"open"}"#
    )

    // when
    let parked = await dispatcher.dispatch(call: call, context: Self.untaintedContext)

    // then
    let recorded = try #require(parked.requiresApproval)
    #expect(parked.observation.status == .blockedPendingApproval)
    #expect(recorded.canonicalTarget == "linear (https://mcp.test.invalid/mcp)")
    #expect(recorded.presentation.blastRadius == "MCP: linear · list_issues")
    #expect(await server.calledTools.isEmpty)

    // when
    let run = try makeSuspendedRun()
    let commit = await ApprovedActionExecutor(
      tools: dispatcher.toolsByName,
      runs: run.runs,
      redactArguments: { $0 },
      now: { Date() },
      logger: Self.silentLogger
    ).executeApproved(approval(run, recorded: recorded))

    // then
    #expect(commit == .committed)
    #expect(try run.observationContent() == "ISSUE-1: the roof leaks")
    #expect(await server.calledTools == ["list_issues"])
    #expect(try run.sessionIsTainted())
  }

  @Test("an MCP token quoted back by the server is redacted out of the tool's result")
  func remoteTextIsRedactedWithTheBootUnion() async throws {
    // given: the token reaches the builder's redactor only through the boot union
    let server = ScriptedMCPHTTPServer(
      tools: [RemoteTool(name: "list_issues")],
      outcome: .text("your bearer is linear-token")
    )
    let builder = try makeBuilder(
      http: server,
      servers: [try serverConfig()],
      credentials: ["linear": .token("linear-token")]
    )
    let dispatcher = try makeDispatcher(
      builder,
      mcpTools: await builder.resolveMCPStack().tools
    )
    let tool = try #require(dispatcher.toolsByName["mcp__linear__list_issues"])

    // when
    let payload = await tool.execute(
      arguments: .object(["query": .string("open")]),
      canonicalTarget: "linear (https://mcp.test.invalid/mcp)"
    )

    // then
    #expect(payload.content.contains("linear-token") == false)
    #expect(payload.ingestedUntrusted)
  }

  // MARK: Boot path

  @Test("an unreachable server is skipped; the built-ins and the doctor row both survive it")
  func unreachableServerIsSkipped() async throws {
    // given: an executor with nothing scripted refuses every attempt, as an unreachable host would
    let builder = try makeBuilder(http: ScriptedHTTPExecutor([]), servers: [try serverConfig()])

    // when
    let stack = await builder.resolveMCPStack()
    let dispatcher = try makeDispatcher(builder, mcpTools: stack.tools)

    // then
    #expect(stack.tools.isEmpty)
    #expect(
      dispatcher.definitions.map(\.name) == [
        "file_read", "file_write", "memory_write", "skill_load", "web_fetch",
      ]
    )

    let outcome = try #require(stack.catalog.outcomes.first)
    #expect(outcome.server == "linear")
    guard case .skipped = outcome.status else {
      Issue.record("expected the unreachable server to be skipped, got \(outcome.status)")
      return
    }

    let row = try #require(
      MCPDoctorRows.bootRows(outcomes: stack.catalog.outcomes).first
    )
    #expect(row.key == "mcp.linear.tools")
    #expect(row.ok == false)
    #expect(row.value.hasPrefix("skipped: "))
  }

  @Test("a boot with no MCP config leaves the tool surface exactly as it was")
  func noConfigLeavesTheSurfaceUnchanged() async throws {
    // given
    let builder = try makeBuilder(http: ScriptedHTTPExecutor([]), servers: [])

    // when
    let stack = await builder.resolveMCPStack()
    let dispatcher = try makeDispatcher(builder, mcpTools: stack.tools)

    // then
    #expect(stack.catalog == .empty)
    #expect(
      dispatcher.definitions.map(\.name) == [
        "file_read", "file_write", "memory_write", "skill_load", "web_fetch",
      ]
    )
    #expect(MCPDoctorRows.rows(config: .empty, credentials: [:]).map(\.key) == ["mcp"])
  }
}

// MARK: - Fixtures

private typealias RemoteTool = ScriptedMCPHTTPServer.RemoteTool

private extension MCPCompositionAcceptanceTests {
  static let silentLogger = Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })

  /// A taint-free, no-private-data context: the ask tier is then the only thing that can park a
  /// call, which is what makes the approval below an assertion about the MCP tier and nothing else.
  static let untaintedContext = ToolDispatchContext(
    sessionTainted: false,
    runIngestedUntrusted: false,
    assemblyPrivateData: false,
    runPrivateData: false,
    sessionHasPrivateData: false,
    approvalAlreadyPending: false
  )

  func serverConfig(
    name: String = "linear",
    url: String = "https://mcp.test.invalid/mcp",
    headers: [String: String] = [:],
    authHeader: String = MCPLimits.defaultAuthHeader,
    tools: MCPToolFilter = .allowAll
  ) throws -> MCPServerConfig {
    try MCPServerConfig(
      name: name,
      url: url,
      headers: headers,
      authHeader: authHeader,
      tools: tools
    )
  }

  func makeBuilder(
    http: any HTTPExecuting & HTTPStreaming,
    servers: [MCPServerConfig],
    config: AppConfig? = nil,
    credentials: [String: MCPCredentialLoad] = [:]
  ) throws -> DaemonBuilder {
    let config = try config ?? CompositionAcceptance.chatGPTConfig()
    let inputs = MCPBootInputs(
      config: try MCPConfig(servers: servers),
      credentials: credentials,
      credentialRedactionValues: credentials.values.compactMap(\.token)
    )
    let secrets = Secrets(telegramBotToken: "tg-token", llmApiKey: nil, searchApiKey: nil)

    return try CompositionAcceptance.makeBuilder(
      http: http,
      config: config,
      secrets: secrets,
      mcp: inputs
    )
  }

  func makeDispatcher(
    _ builder: DaemonBuilder,
    mcpTools: [any Tool]
  ) throws -> GatedToolDispatcher {
    builder.makeToolDispatcher(
      workspace: FileSystemWorkspace(
        root: EnvironmentLoader.workspaceRoot(config: builder.config)
      ),
      sandbox: SandboxBootstrapResult(
        backend: nil,
        maintenance: nil,
        health: nil,
        unavailableReason: nil
      ),
      mcpTools: mcpTools
    )
  }

  func subhash(
    _ server: ScriptedMCPHTTPServer,
    _ config: AppConfig,
    _ servers: [MCPServerConfig]
  ) async throws -> String {
    let builder = try makeBuilder(http: server, servers: servers, config: config)
    let dispatcher = try makeDispatcher(builder, mcpTools: await builder.resolveMCPStack().tools)
    return builder.policyStaticSubhash(
      toolDispatcher: dispatcher,
      workspace: FileSystemWorkspace(
        root: EnvironmentLoader.workspaceRoot(config: builder.config)
      )
    )
  }
}

// MARK: - Approved-execution fixture

/// A run parked at AWAITING_APPROVAL with the placeholder observation the suspend commit leaves —
/// the state the approved executor is only ever entered from.
private struct SuspendedRun {
  let queue: DatabaseQueue
  let runs: RunStoreGRDB
  let sessionId: Int64
  let runId: Int64
  let observationMessageId: Int64

  /// Whether the executed result tainted the session — the durable half of `ingestedUntrusted`,
  /// which is what keeps the trifecta gate armed for the rest of the session.
  func sessionIsTainted() throws -> Bool {
    try queue.read { database in
      try Bool.fetchOne(
        database,
        sql: "SELECT tainted FROM sessions WHERE id = ?",
        arguments: [sessionId]
      ) ?? false
    }
  }

  func observationContent() throws -> String? {
    try queue.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT content FROM messages WHERE id = ?",
        arguments: [observationMessageId]
      )
    }
  }
}

private extension MCPCompositionAcceptanceTests {
  func makeSuspendedRun() throws -> SuspendedRun {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)

    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 7),
        chatId: 7,
        userId: 7,
        text: "list the open issues",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    let runs = RunStoreGRDB(writer: queue)
    _ = try #require(try runs.pickUp(runId: runId, now: Date()))

    let observationMessageId = try queue.write { database -> Int64 in
      try database.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', 'awaiting owner approval', 'trusted', ?, 'c1')
          """,
        arguments: [sessionId, runId, Date()]
      )
      let messageId = database.lastInsertedRowID
      _ = try RunStoreGRDB.transitionRun(
        database,
        runId: runId,
        event: .suspendForApproval,
        now: Date(),
        terminal: nil
      )
      return messageId
    }

    return SuspendedRun(
      queue: queue,
      runs: runs,
      sessionId: sessionId,
      runId: runId,
      observationMessageId: observationMessageId
    )
  }

  func approval(_ run: SuspendedRun, recorded: RecordedToolAction) -> Approval {
    Approval(
      id: 1,
      runId: run.runId,
      sessionId: run.sessionId,
      state: .approved,
      tool: recorded.tool,
      canonicalArgsJSON: recorded.canonicalArgsJSON,
      canonicalTarget: recorded.canonicalTarget,
      argsHash: recorded.argsHash,
      policyVersion: "pv",
      ownerUserId: 7,
      nonce: "nonce-a",
      observationMessageId: run.observationMessageId,
      toolCallId: "c1",
      reason: recorded.reason,
      promptMessageId: 900,
      createdTs: Date(),
      expiresTs: Date(),
      resolvedTs: Date()
    )
  }
}
