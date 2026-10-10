import ClawCoder
import ClawCore
import ClawData
import ClawSubprocess
import ClawTelegram
import ClawTestSupport
import ClawTools
import ClawWorkspace
import Foundation
import GRDB
import Testing

@testable import ClawLLM
@testable import ClawGateway
@testable import clawd

@Suite
struct JournalCompositionTests {
  @Test
  func journalSurvivesResetAndRestartInComposedGraph() async throws {
    // given — run the production build, poller and worker over real SQLite and files.
    let fixture = try JournalCompositionFixture(enabled: true)
    defer {
      fixture.removeFiles()
    }
    let firstScript = JournalPollerScript(
      updates: [
        fixture.updateJSON(id: 1, text: "Choose SQLite"),
        fixture.updateJSON(id: 2, text: "/new"),
      ]
    )
    let provider = SequenceProvider([
      fixture.response("Choose SQLite because transactions matter."),
      fixture.response(
        """
        {"notes":[{"kind":"decision","attribution":"owner",
        "text":"Chose SQLite for transactions.","source_ids":["message:1"]}]}
        """
      ),
    ])

    // when — the deployed graph captures an exchange, resets and completes admitted Coder work.
    let jobID = try await fixture.withRunningBundle(provider: provider, script: firstScript) {
      bundle in
      try #require(await firstScript.exchangeDelivered.waitUntilOpen())
      let service = try #require(bundle.coder)
      let prepared = try await service.prepare(CoderCompositionFixture.request)
      let queue = try DatabaseQueue(
        path: EnvironmentLoader.databasePath(config: fixture.builder.config)
      )
      let origin = try CoderApprovedOriginFixture.make(
        queue: queue,
        updateID: 90,
        prepared: prepared,
        now: fixture.now,
        ownerID: 777
      )
      let job = try await service.submit(
        prepared,
        context: ToolExecutionContext(
          runID: origin.runID,
          sessionID: origin.sessionID,
          chatID: 777,
          requesterUserID: 777,
          origin: .interactive,
          mode: .direct,
          toolCallID: origin.toolCallID,
          approvalID: origin.approvalID
        )
      )
      try #require(await fixture.backend.started.waitUntilOpen())
      firstScript.allowNextUpdate.open()
      try #require(await firstScript.resetDelivered.waitUntilOpen())
      try #require(await fixture.waitForPublishedNote("Chose SQLite for transactions."))
      fixture.backend.releaseAll()
      try #require(await firstScript.coderDelivered.waitUntilOpen())
      #expect(try fixture.builder.stores.coderJobs.job(id: job.id)?.state == .succeeded)
      return job.id
    }
    let reopened = try fixture.reopen(disablingJournal: false)
    let secondScript = JournalPollerScript(
      updates: [
        fixture.updateJSON(id: 4, text: "/new"),
        fixture.updateJSON(id: 3, text: "What did we decide?"),
      ]
    )
    let resumedProvider = SequenceProvider([
      fixture.response(
        """
        {"notes":[{"kind":"result","attribution":"worker_report",
        "text":"Coder completed the retry fix.","source_ids":["coder:\(jobID.uuidString)"]}]}
        """
      ),
      fixture.response("I remember the decision and completed fix."),
    ])
    try await reopened.withRunningBundle(provider: resumedProvider, script: secondScript) { _ in
      try #require(await secondScript.resetDelivered.waitUntilOpen())
      try #require(await reopened.waitForPublishedNote("Coder completed the retry fix."))
      secondScript.allowNextUpdate.open()
      try #require(await secondScript.exchangeDelivered.waitUntilOpen())
    }

    // then — actual next-provider context contains notes outside the reset conversation window.
    let requests = await resumedProvider.requests
    #expect(requests.count == 2)
    let text = try #require(requests.last).messages.map(\.content.text).joined(separator: "\n")
    #expect(text.contains("Chose SQLite for transactions."))
    #expect(text.contains("Coder completed the retry fix."))
  }

  enum ExcludedRoute: CaseIterable {
    case disabled, scheduled
  }

  @Test(arguments: ExcludedRoute.allCases)
  func excludedRoutesOmitJournalContext(route: ExcludedRoute) async throws {
    // given — dated files exist, so a missing reader gate would reach the provider request.
    let fixture = try JournalCompositionFixture(enabled: route != .disabled)
    defer {
      fixture.removeFiles()
    }
    let provider = SequenceProvider([fixture.response("Ordinary reply")])
    let graph = fixture.graph(provider: provider)
    let day = JournalDay.containing(fixture.now, timeZone: fixture.builder.config.timezone)
    try graph.files.append(day: day, text: "excludedPrivateJournalNote")
    let runner = await fixture.runner(graph: graph, provider: provider)
    let claim: ClaimResult
    switch route {
    case .scheduled:
      let job = try fixture.builder.stores.scheduledJobs.create(
        NewScheduledJob(
          ownerChatID: 777,
          label: "digest",
          prompt: "Summarize",
          recurrence: nil,
          timezone: "UTC",
          nextOccurrence: fixture.now
        ),
        now: fixture.now
      )
      guard case .fired(let fired) = try fixture.builder.stores.scheduledJobs.fireNow(
        jobID: job.id,
        now: fixture.now
      )
      else {
        Issue.record("Scheduled fixture did not fire")
        return
      }
      claim = ClaimResult(
        newlyClaimed: true,
        sessionID: fired.sessionID,
        messageID: fired.triggerMessageID,
        runID: fired.runID,
        triggerMessageID: fired.triggerMessageID
      )
    case .disabled:
      claim = try fixture.builder.stores.sessionMessages.claimAndPersistInbound(
        InboundMessage(
          updateID: 1,
          sessionKey: SessionKey.telegramDM(chatID: 777),
          chatID: 777,
          userID: 777,
          text: "Ordinary message",
          isEdited: false,
          provenance: .trusted,
          journalAdmission: nil,
          ts: fixture.now
        )
      )
    }

    // when
    try await runner.run(
      runID: #require(claim.runID),
      sessionID: #require(claim.sessionID),
      chatID: 777,
      triggerMessageID: #require(claim.messageID)
    )
    await graph.worker?.sweep(now: fixture.now)
    await graph.worker?.shutdown()

    // then — composed context excludes journal notes for disabled and scheduled routes.
    let requests = await provider.requests
    #expect(requests.count == 1)
    let text = try #require(requests.first).messages.map(\.content.text).joined()
    #expect(text.contains("excludedPrivateJournalNote") == false)
    if route == .disabled {
      #expect(graph.worker == nil)
      #expect(graph.capture == nil)
    }
  }

  @Test(arguments: [WorkspaceFile.memory, WorkspaceFile.user])
  func enabledCompositionScansBothPrivateArgumentFiles(file: WorkspaceFile) async throws {
    // given — the real loader must read each distinct workspace input on a clean turn.
    let fixture = try JournalCompositionFixture(enabled: true)
    defer {
      fixture.removeFiles()
    }
    let privateText = "OwnerPrivateDetail123456789"
    try privateText.write(
      to: fixture.workspace.root.appendingPathComponent(file.relativePath),
      atomically: true,
      encoding: .utf8
    )
    let graph = fixture.graph(provider: SequenceProvider([]))
    let stack = await fixture.stack(graph: graph, provider: SequenceProvider([]))

    // when — the substring would leave through a fetch without the composed journal flag/loader.
    let outcome = await stack.toolDispatcher.dispatch(
      call: ToolCall(
        id: "private-fetch",
        name: BuiltinToolNames.webFetch,
        argumentsJSON: "{\"url\":\"https://example.com/?detail=\(privateText)\"}"
      ),
      context: ToolDispatchContext(
        sessionTainted: false,
        runIngestedUntrusted: false,
        assemblyPrivateData: false,
        runPrivateData: false,
        sessionHasPrivateData: false,
        approvalAlreadyPending: false
      )
    )
    await graph.worker?.shutdown()

    // then — the argument guard blocks disclosure without adding an approval card.
    #expect(outcome.observation.status == .blockedArgs)
    #expect(outcome.requiresApproval == nil)
  }

  @Test
  func disabledBootAccountsStartedJournalWithoutModelOrFileIO() async throws {
    // given — a summary receipt was durably started before the prior process disappeared.
    let fixture = try JournalCompositionFixture(enabled: true)
    defer {
      fixture.removeFiles()
    }
    let provider = SequenceProvider([fixture.response("Choose SQLite")])
    let graph = fixture.graph(provider: provider)
    let runner = await fixture.runner(graph: graph, provider: provider)
    let completed = AsyncGate()
    let router = fixture.router(
      graph: graph,
      runner: JournalCompositionTurns(runner: runner, completed: completed)
    )
    #expect(
      await router.handle(rawUpdate: fixture.update(id: 1, text: "Choose SQLite")) == .processed
    )
    #expect(await completed.waitUntilOpen())
    #expect(await router.handle(rawUpdate: fixture.update(id: 2, text: "/new")) == .processed)
    let sources = try graph.store.pendingSources(ownerUserID: 777, now: fixture.now)
    let codec = JournalSummaryCodec(
      costResolver: CostResolver.configured(by: fixture.builder.config),
      redact: {
        $0
      }
    )
    let binding = fixture.roster(provider).primary
    let prepared = try codec.prepare(sources: sources, binding: binding, budget: .default)
    let callID = UUIDProviderCallIDGenerator().next()
    let sessionID = try #require(sources.first).sessionID
    let saved = prepared.accountant.conservativeRow(
      callID: callID,
      context: prepared.request.messages,
      observedCompletionTokens: 0,
      runID: nil,
      sessionID: sessionID
    )
    let start = try graph.store.startBatch(
      JournalStartRequest(
        sourceIDs: sources.map(\.id),
        scope: #require(sources.first).scope,
        day: #require(sources.first).day,
        sessionID: sessionID,
        providerCallID: callID,
        estimate: prepared.estimate,
        conservativeUsage: saved,
        budget: .default,
        costPolicy: .metered
      ),
      now: fixture.now
    )
    guard case .started = start else {
      Issue.record("Fixture did not start the journal receipt")
      return
    }
    await graph.worker?.shutdown()
    let disabled = try fixture.reopen(disablingJournal: true)
    let disabledGraph = disabled.graph(provider: provider)
    let stack = await disabled.stack(graph: disabledGraph, provider: provider)
    let disabledRunner = await disabled.runner(graph: disabledGraph, provider: provider)
    let approvals = disabled.builder.makeApprovalFabric(
      coordination: disabled.coordination,
      agentStack: stack,
      turnRunner: disabledRunner
    )
    let boot = disabled.builder.bootSequence(
      coordination: disabled.coordination,
      waiter: approvals.waiter,
      heartbeatOwner: nil,
      learning: nil
    )

    // when — even disabling the worker must reconcile the saved exposure exactly once.
    await boot()
    await boot()

    // then
    #expect(disabledGraph.worker == nil)
    #expect(await provider.requests.count == 1)
    #expect(try disabledGraph.files.recentDays(limit: 10).isEmpty)
    #expect(
      try disabledGraph.store.status(ownerUserID: 777, now: fixture.now).interruptedCount == 1
    )
    let queue = try DatabaseQueue(
      path: EnvironmentLoader.databasePath(config: disabled.builder.config)
    )
    let count = try await queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM provider_usage WHERE provider_call_id = ?",
        arguments: [callID.rawValue]
      )
    }
    #expect(count == 1)
  }

  @Test
  func configurationDoctorDoesNotTouchJournalState() async throws {
    // given — invoke the real command in a minimal environment, with no secret or network endpoint.
    let root = try makeTemporaryRoot(prefix: "journal-config-doctor")
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/debug/clawd")
    let command = SubprocessCommand(
      arguments: [
        "-i",
        "PATH=/usr/bin:/bin",
        "CLAW_STATE_ROOT=\(root.path)",
        "CLAW_LLM_MODEL=test-model",
        "CLAW_LLM_BASE_URL=http://localhost:9/v1",
        "CLAW_LLM_INPUT_USD_PER_MTOK=0",
        "CLAW_LLM_OUTPUT_USD_PER_MTOK=0",
        "CLAW_ALLOWLIST=777",
        "CLAW_JOURNAL_ENABLED=true",
        executable.path,
        "doctor",
        "--check-config",
        "--json",
      ],
      timeout: .seconds(30),
      captureLimit: 64 * 1024,
      teardownGracePeriod: .seconds(2)
    )

    // when
    let result = await SwiftSubprocessRunner(executablePath: "/usr/bin/env").run(command)
    let report = try #require(
      JSONSerialization.jsonObject(with: result.stdout.bytes) as? [String: Any]
    )
    let checks = try #require(report["checks"] as? [[String: Any]])
    let row = checks.first {
      $0["key"] as? String == "journal.enabled"
    }

    // then — config rows need no store construction, file enumeration or summary request.
    #expect(result.termination == .exited(ClawExitCode.secretLoadFailed.rawValue))
    #expect(row?["value"] as? String == "on")
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent(StateFile.database).path)
        == false
    )
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace/memory").path)
        == false
    )
  }

}

// MARK: - Composition Fixture

struct JournalCompositionFixture {
  let backend: ScriptedCoderBackend
  let builder: DaemonBuilder
  let now = Date(timeIntervalSince1970: 1_791_460_800)
  var root: URL {
    builder.config.stateRoot
  }

  var workspace: FileSystemWorkspace {
    FileSystemWorkspace(root: EnvironmentLoader.workspaceRoot(config: builder.config))
  }

  let coordination = DaemonBuilder.TurnCoordination()
  let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: ContinuousClock())

  init(enabled: Bool) throws {
    var env = CompositionAcceptanceHarness.validEnv()
    env["CLAW_ALLOWLIST"] = "777"
    env["CLAW_JOURNAL_ENABLED"] = enabled ? "true" : "false"
    env["CLAW_CODER_ENABLED"] = "true"
    env["CLAW_LLM_STREAMING"] = "false"
    env["CLAW_TELEGRAM_PROGRESS"] = "false"
    var builder = try CompositionAcceptance.makeBuilder(
      http: ScriptedHTTPExecutor([]),
      config: AppConfig.load(environment: env)
    )
    let backend = ScriptedCoderBackend(invocations: [
      ScriptedCoderBackend.Invocation(result: CoderCompositionFixture.result),
    ])
    self.backend = backend
    builder.resolveCoder = { config in
      CoderBackendSetup(
        backend: backend,
        executable: "/test/codex",
        profile: config.profile,
        configHome: "/test/config",
        credentialSources: [:],
        version: "scripted",
        authentication: .authenticated
      )
    }
    let date = now
    builder.now = {
      date
    }
    try FileManager.default.createDirectory(
      at: EnvironmentLoader.workspaceRoot(config: builder.config),
      withIntermediateDirectories: true
    )
    try builder.stores.allowlist.seedAllowlist(userIDs: [777])
    self.builder = builder
  }

  private init(builder: DaemonBuilder) {
    self.builder = builder
    backend = ScriptedCoderBackend(invocations: [
      ScriptedCoderBackend.Invocation(result: CoderCompositionFixture.result),
    ])
  }

  func reopen(disablingJournal: Bool) throws -> Self {
    let config: AppConfig
    if disablingJournal {
      var env = CompositionAcceptanceHarness.validEnv()
      env[AppConfig.EnvKey.stateRoot] = root.path
      env["CLAW_ALLOWLIST"] = "777"
      env["CLAW_JOURNAL_ENABLED"] = "false"
      env["CLAW_LLM_STREAMING"] = "false"
      config = try AppConfig.load(environment: env)
    } else {
      config = builder.config
    }
    var reopened = try CompositionAcceptance.makeBuilder(
      http: ScriptedHTTPExecutor([]),
      config: config
    )
    let date = now
    reopened.now = {
      date
    }
    reopened.resolveCoder = builder.resolveCoder
    return Self(builder: reopened)
  }

  func bundle(
    provider: SequenceProvider,
    http: ScriptedHTTPExecutor? = nil
  ) async throws -> DaemonRuntimeBundle {
    let activeBuilder: DaemonBuilder
    if let http {
      activeBuilder = DaemonBuilder(
        config: builder.config,
        secrets: builder.secrets,
        stores: builder.stores,
        toolExecutor: http,
        transport: .init(token: builder.secrets.telegramBotToken, http: http),
        botIdentity: builder.botIdentity,
        mcp: builder.mcp,
        logger: builder.logger,
        now: builder.now,
        makeManagedStore: builder.makeManagedStore,
        resolveCoder: builder.resolveCoder
      )
    } else {
      activeBuilder = builder
    }
    return try await activeBuilder.build(
      rosterStack: RosterStack(roster: roster(provider), credentialSources: []),
      cooldown: cooldown
    )
  }

  func withRunningBundle<Value: Sendable>(
    provider: SequenceProvider,
    script: JournalPollerScript,
    operation: (DaemonRuntimeBundle) async throws -> Value
  ) async throws -> Value {
    let http = ScriptedHTTPExecutor(
      Array(
        repeating: .responding { request in
          try await script.respond(to: request)
        },
        count: 100
      )
    )
    let bundle = try await bundle(provider: provider, http: http)
    let daemon = Task {
      try await bundle.daemon.run()
    }
    do {
      let value = try await operation(bundle)
      daemon.cancel()
      _ = await daemon.result
      return value
    } catch {
      daemon.cancel()
      _ = await daemon.result
      throw error
    }
  }

  func updateJSON(id: Int64, text: String) -> String {
    """
    {"ok":true,"result":[{"update_id":\(id),"message":{"message_id":\(id),
    "date":\(Int(now.timeIntervalSince1970)),"from":{"id":777},
    "chat":{"id":777,"type":"private"},"text":"\(text)"}}]}
    """
  }

  func waitForPublishedNote(_ text: String) async -> Bool {
    let files = FileSystemJournalFiles(root: workspace.root)
    let day = JournalDay.containing(now, timeZone: builder.config.timezone)
    return await withTestWatchdog(
      onTimeout: {
        Issue.record("The production journal worker did not publish its notified batch")
      },
      {
        while !Task.isCancelled {
          if files.load(day: day).text.contains(text) {
            return true
          }
          await Task.yield()
        }
        return false
      }
    )
  }

  func response(_ content: String) -> ChatResponse {
    ChatResponse(content: content, finishReason: "stop", usage: nil, costFromProvider: nil)
  }

  func roster(_ provider: SequenceProvider) -> ProviderRoster {
    ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: "gpt-4o",
        configuredReference: "gpt-4o",
        costPolicy: .metered,
        reservationPolicy: .textOnly
      )
    )
  }

  func graph(provider: SequenceProvider) -> DaemonBuilder.JournalComposition {
    builder.makeJournalComposition(
      roster: roster(provider),
      cooldown: cooldown,
      costResolver: CostResolver.configured(by: builder.config),
      workspaceRoot: workspace.root
    )
  }

  func runner(
    graph: DaemonBuilder.JournalComposition,
    provider: SequenceProvider
  ) async -> TurnRunner {
    let stack = await stack(graph: graph, provider: provider)
    return builder.makeTurnRunner(
      coordination: coordination,
      agentStack: stack,
      costPolicy: .metered,
      imageCache: ImageCache(),
      freezeLearningSurface: { _, _ in },
      journal: graph
    )
  }

  func stack(
    graph: DaemonBuilder.JournalComposition,
    provider: SequenceProvider
  ) async -> DaemonBuilder.AgentStack {
    return builder.makeAgentStack(
      roster: roster(provider),
      cooldown: cooldown,
      workspace: workspace,
      costResolver: CostResolver.configured(by: builder.config),
      sandbox: await builder.prepareSandbox(),
      mcpTools: [],
      journal: graph
    )
  }

  func router(graph: DaemonBuilder.JournalComposition, runner: any TurnDispatching) -> MessageRouter
  {
    builder.makeIntakeRouter(
      coordination: coordination,
      turnRunner: runner,
      imageCache: ImageCache(),
      scheduleSurface: builder.makeScheduleSurface(
        roster: roster(SequenceProvider([])),
        cooldown: cooldown,
        costResolver: CostResolver.configured(by: builder.config)
      ),
      approvalCallbacks: nil,
      doctor: JournalCompositionDoctor(),
      learning: nil,
      presentations: nil,
      journal: graph
    )
  }

  func update(id: Int64, text: String) -> RawUpdate {
    RawUpdate(
      updateID: id,
      message: RawMessage(
        messageID: id,
        fromUserID: 777,
        chatID: 777,
        text: text,
        caption: nil,
        mediaKind: nil,
        chatKind: .private,
        chatTitle: nil,
        messageThreadID: nil,
        senderDisplayName: nil,
        date: now
      ),
      editedMessage: nil
    )
  }

  func removeFiles() {
    backend.releaseAll()
    try? FileManager.default.removeItem(at: root)
  }
}

private struct JournalCompositionDoctor: DoctorReporting {
  func report() async -> DoctorReport {
    DoctorReport()
  }

  func scanSkills() async -> SkillScanResult {
    SkillScanResult(descriptors: [], warnings: [])
  }
}

private struct JournalCompositionTurns: TurnDispatching {
  let runner: TurnRunner
  let completed: AsyncGate

  func run(runID: Int64, sessionID: Int64, chatID: Int64, triggerMessageID: Int64) async throws {
    defer {
      completed.open()
    }
    try await runner.run(
      runID: runID,
      sessionID: sessionID,
      chatID: chatID,
      triggerMessageID: triggerMessageID
    )
  }
}

// MARK: - Poller Script

actor JournalPollerScript {
  nonisolated let allowNextUpdate = AsyncGate()
  nonisolated let exchangeDelivered = AsyncGate()
  nonisolated let resetDelivered = AsyncGate()
  nonisolated let coderDelivered = AsyncGate()
  private let parkedPoll = AsyncGate()
  private var updates: [String]
  private var pollCount = 0

  init(updates: [String]) {
    self.updates = updates
  }

  func respond(to request: HTTPRequest) async throws -> HTTPResult {
    if request.url.hasSuffix("/getUpdates") {
      pollCount += 1
      if updates.isEmpty {
        await parkedPoll.wait()
        try Task.checkCancellation()
        return result("{\"ok\":true,\"result\":[]}")
      }
      let payload = updates.removeFirst()
      if pollCount > 1 {
        await allowNextUpdate.wait()
      }
      try Task.checkCancellation()
      return result(payload)
    }
    if request.url.hasSuffix("/sendMessage") || request.url.hasSuffix("/sendRichMessage") {
      let payload = try #require(
        request.body.flatMap { body in
          String(data: body, encoding: .utf8)
        }
      )
      if payload.contains("Choose SQLite because transactions matter.")
         || payload.contains("I remember the decision and completed fix.")
      {
        exchangeDelivered.open()
      }
      if payload.contains(CommandReplies.freshConversation) {
        resetDelivered.open()
      }
      if payload.contains("Completed") {
        coderDelivered.open()
      }
      return result("{\"ok\":true,\"result\":{\"message_id\":100,\"chat\":{\"id\":777}}}")
    }
    return result("{\"ok\":true,\"result\":true}")
  }

}

// MARK: - Responses

private extension JournalPollerScript {
  func result(_ payload: String) -> HTTPResult {
    HTTPResult(statusCode: 200, headers: [:], body: Data(payload.utf8))
  }
}
