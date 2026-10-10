import ClawTestSupport
import ClawWorkspace
import Foundation
import GRDB
import Testing

@testable import ClawCore
@testable import ClawGateway
@testable import clawd

@Suite
struct TelegramProgressCompositionTests {
  enum Scenario: CaseIterable {
    case enabled
    case progressOff
    case streamingOff
    case topic
    case proactive

    var expectsProgress: Bool {
      self == .enabled
    }

    var expectsAnswer: Bool {
      self == .enabled || self == .progressOff
    }
  }

  @Test(arguments: Scenario.allCases)
  func composedProgressRespectsStreamingAndChatMode(scenario: Scenario) async throws {
    // given
    let signals = ProgressCompositionSignals()
    let http = Self.makeHTTP(signals: signals)
    let provider = ProgressCompositionProvider()
    let fixture = try Self.makeFixture(scenario: scenario, http: http, provider: provider)
    let builder = fixture.builder
    defer {
      try? FileManager.default.removeItem(at: builder.config.stateRoot)
      provider.answer.open()
      provider.finish.open()
    }
    let chatID: Int64 = scenario == .topic ? -7 : 7
    if scenario == .enabled {
      try Self.seedOlderAnswer(builder, chatID: chatID)
    }
    let claim = try Self.claim(builder, scenario: scenario, chatID: chatID)
    let runID = try #require(claim.runID)
    let sessionID = try #require(claim.sessionID)
    let trigger = try #require(claim.triggerMessageID)
    let task = Task {
      try await fixture.runner.run(
        runID: runID,
        sessionID: sessionID,
        chatID: chatID,
        triggerMessageID: trigger
      )
    }

    // when
    #expect(await provider.started.waitUntilOpen())
    #expect(await signals.typing.waitUntilOpen())
    if scenario == .enabled {
      await fixture.consumers.outbox.drainOnce()
      #expect(await signals.progressDrafts.waitUntilOpen())
    }
    provider.answer.open()
    if scenario.expectsAnswer || scenario == .proactive {
      #expect(await signals.answerDrafts.waitUntilOpen())
    }
    provider.finish.open()
    try await task.value

    // then
    let requests = await http.recorded
    let draftBodies = requests.filter { $0.url.hasSuffix("/sendRichMessageDraft") }
      .map(\.body).compactMap { String(data: $0, encoding: .utf8) }
    #expect(draftBodies.contains { $0.contains("tg-thinking") } == scenario.expectsProgress)
    if scenario == .proactive {
      #expect(
        draftBodies.allSatisfy {
          !$0.contains("can_stop") && !$0.contains("keep_on_stop")
        }
      )
    }
    let draftIDs = await signals.draftIDs
    if scenario.expectsAnswer {
      // Proactive runs can stream into the same chat from another session lane.
      #expect(draftIDs.isEmpty == false)
      #expect(
        draftIDs.allSatisfy {
          $0 < 0
        }
      )
    } else if scenario == .proactive {
      #expect(
        draftIDs.allSatisfy {
          $0 == runID && $0 > 0
        }
      )
    }
    if scenario != .proactive {
      #expect(
        draftBodies.contains { $0.contains(ProgressCompositionProvider.answerText) }
          == scenario.expectsAnswer
      )
    }
    #expect(await provider.request?.progressExplanationsEnabled == scenario.expectsProgress)
    let targets = await signals.typingTargets
    #expect(targets.isEmpty == false)
    #expect(
      targets.allSatisfy {
        $0 == DeliveryTarget(chatID: chatID, messageThreadID: scenario == .topic ? 17 : nil)
      }
    )
  }
}

extension TelegramProgressCompositionTests {
  @Test
  func composedProgressRedactsTheBootSecretUnion() async throws {
    // given — the MCP credential exists only in boot inputs, not the provider or ordinary secrets.
    let signals = ProgressCompositionSignals()
    let http = Self.makeHTTP(signals: signals)
    let provider = SecretProgressProvider()
    let fixture = try Self.makeFixture(
      scenario: .enabled,
      http: http,
      provider: provider,
      secrets: Secrets(
        telegramBotToken: "tg-token",
        llmAPIKey: nil,
        searchAPIKey: SecretProgressProvider.rootSecret
      ),
      mcp: MCPBootInputs(
        config: try MCPConfig(servers: [
          try MCPServerConfig(name: "search", url: "https://mcp.test.invalid/mcp"),
        ]),
        credentials: ["search": .token(SecretProgressProvider.mcpSecret)],
        credentialRedactionValues: [SecretProgressProvider.mcpSecret]
      )
    )
    defer {
      provider.toolRound.open()
      provider.finish.open()
      try? FileManager.default.removeItem(at: fixture.builder.config.stateRoot)
    }
    let claim = try Self.claim(fixture.builder, scenario: .enabled, chatID: 7)
    let runID = try #require(claim.runID)
    let sessionID = try #require(claim.sessionID)
    let trigger = try #require(claim.triggerMessageID)
    let turn = Task {
      try await fixture.runner.run(
        runID: runID,
        sessionID: sessionID,
        chatID: 7,
        triggerMessageID: trigger
      )
    }

    // when — observe each stage before answer replacement can erase the evidence.
    let explanationSeen = await signals.secretExplanation.waitUntilOpen()
    provider.toolRound.open()
    let previewSeen = await signals.secretPreview.waitUntilOpen()
    provider.finish.open()
    try await turn.value

    // then
    #expect(explanationSeen && previewSeen)
    let frames = await signals.secretFrames
    let replacement = SecretRedactor.replacement
    #expect(frames.contains { $0.contains("Root \(replacement); MCP \(replacement)") })
    #expect(frames.contains { $0.contains("preview: \(replacement)") })
    #expect(frames.allSatisfy { !$0.contains(SecretProgressProvider.rootSecret) })
    #expect(frames.allSatisfy { !$0.contains(String(SecretProgressProvider.mcpSecret.prefix(40))) })
  }
}

// MARK: - Production Composition

private extension TelegramProgressCompositionTests {
  static func makeHTTP(signals: ProgressCompositionSignals) -> ScriptedHTTPExecutor {
    ScriptedHTTPExecutor(
      (0..<100).map { _ in
        .responding { request in
          try await signals.observe(request)
          return HTTPResult(
            statusCode: 200,
            headers: [:],
            body: request.url.hasSuffix("/sendRichMessage")
              ? Data(#"{"ok":true,"result":{"message_id":900,"chat":{"id":7}}}"#.utf8)
              : Data(#"{"ok":true,"result":true}"#.utf8)
          )
        }
      }
    )
  }

  static func makeFixture(
    scenario: Scenario,
    http: ScriptedHTTPExecutor,
    provider: any LLMProvider,
    secrets: Secrets = Secrets(telegramBotToken: "tg-token", llmAPIKey: nil),
    mcp: MCPBootInputs = .empty
  ) throws -> (
    builder: DaemonBuilder,
    runner: TurnRunner,
    consumers: DaemonBuilder.RunnerConsumers
  ) {
    var environment = CompositionAcceptanceHarness.validEnv()
    environment[AppConfig.EnvKey.allowlist] = "7"
    environment[AppConfig.EnvKey.groupChats] = scenario == .topic ? "-7" : nil
    environment[AppConfig.EnvKey.llmStreaming] = scenario == .streamingOff ? "false" : "true"
    environment[AppConfig.EnvKey.telegramProgress] = scenario == .progressOff ? "false" : "true"
    let config = try AppConfig.load(environment: environment)
    let builder = try CompositionAcceptance.makeBuilder(
      http: http,
      config: config,
      secrets: secrets,
      mcp: mcp
    )
    try builder.stores.allowlist.seedAllowlist(userIDs: Array(config.allowlist))
    let roster = makeSingleRouteRoster(provider: provider, wireModel: config.llm.route.wireModel)
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: ContinuousClock())
    let workspace = FileSystemWorkspace(root: EnvironmentLoader.workspaceRoot(config: config))
    let sandbox = SandboxBootstrapResult(
      backend: nil,
      maintenance: nil,
      health: nil,
      unavailableReason: nil
    )
    let costs = CostResolver.configured(by: config)
    let stack = builder.makeAgentStack(
      roster: roster,
      cooldown: cooldown,
      workspace: workspace,
      costResolver: costs,
      sandbox: sandbox,
      mcpTools: [],
      presentationClock: ScriptedClock.compressed(parkingAt: .seconds(1)),
      journal: nil
    )
    let coordination = DaemonBuilder.TurnCoordination()
    let consumers = builder.makeRunnerConsumers(
      coordination: coordination,
      agentStack: stack,
      roster: roster,
      cooldown: cooldown,
      costResolver: costs,
      workspace: workspace,
      sandbox: sandbox,
      mcpCatalog: .empty,
      coder: CoderComposition(service: nil, tools: [], checks: []),
      learning: nil,
      journal: nil
    )
    let runner = builder.makeTurnRunner(
      coordination: coordination,
      agentStack: stack,
      costPolicy: roster.primary.costPolicy,
      imageCache: ImageCache(),
      freezeLearningSurface: { _, _ in },
      journal: nil
    )
    return (builder, runner, consumers)
  }
}

// MARK: - Durable Runs

private extension TelegramProgressCompositionTests {
  static func claim(
    _ builder: DaemonBuilder,
    scenario: Scenario,
    chatID: Int64
  ) throws -> ClaimResult {
    if scenario == .proactive {
      let job = try builder.stores.scheduledJobs.create(
        NewScheduledJob(
          ownerChatID: chatID,
          label: "digest",
          prompt: "Summarize updates",
          recurrence: nil,
          timezone: "UTC",
          nextOccurrence: Date()
        ),
        now: Date()
      )
      guard case .fired(let fired) = try builder.stores.scheduledJobs.fireNow(
        jobID: job.id,
        now: Date()
      )
      else {
        throw StoreError.unexpected("scheduled fixture did not fire")
      }
      return ClaimResult(
        newlyClaimed: true,
        sessionID: fired.sessionID,
        messageID: nil,
        runID: fired.runID,
        triggerMessageID: fired.triggerMessageID
      )
    }
    return try builder.stores.sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateID: scenario == .enabled ? 2 : 1,
        sessionKey: scenario == .topic
          ? SessionKey.telegramTopic(chatID: chatID, threadID: 17)
          : SessionKey.telegramDM(chatID: chatID),
        chatID: chatID,
        userID: 7,
        text: "hello",
        isEdited: false,
        journalAdmission: nil,
        ts: Date()
      )
    )
  }

  static func seedOlderAnswer(_ builder: DaemonBuilder, chatID: Int64) throws {
    let claim = try builder.stores.sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: chatID),
        chatID: chatID,
        userID: chatID,
        text: "earlier",
        isEdited: false,
        journalAdmission: nil,
        ts: Date()
      )
    )
    let runID = try #require(claim.runID)
    _ = try #require(try builder.stores.runs.pickUp(runID: runID, now: Date()))
    let writer = try DatabaseQueue(path: EnvironmentLoader.databasePath(config: builder.config))
    try OutboxFixture.commitReply(
      in: writer,
      runID: runID,
      chunks: [
        OutboxChunk(
          stepIndex: 0,
          chatID: chatID,
          payload: "older answer",
          payloadHash: ContentHash.fnv1a("older answer")
        ),
      ]
    )
  }
}

// MARK: - Unmanaged Boundaries

private actor ProgressCompositionSignals {
  nonisolated let progressDrafts = AsyncGate()
  nonisolated let answerDrafts = AsyncGate()
  nonisolated let typing = AsyncGate()
  nonisolated let secretExplanation = AsyncGate()
  nonisolated let secretPreview = AsyncGate()
  private(set) var secretFrames: [String] = []
  private(set) var typingTargets: [DeliveryTarget] = []
  private(set) var draftIDs: [Int64] = []

  func observe(_ request: HTTPRequest) throws {
    let body = try JSONSerialization.jsonObject(with: request.body ?? Data())
    guard let fields = body as? [String: Any] else {
      return
    }
    if request.url.hasSuffix("/sendChatAction"), let chatID = fields["chat_id"] as? Int64 {
      typingTargets.append(
        DeliveryTarget(chatID: chatID, messageThreadID: fields["message_thread_id"] as? Int64)
      )
      typing.open()
    }
    if request.url.hasSuffix("/sendRichMessageDraft") {
      draftIDs.append(try #require(fields["draft_id"] as? Int64))
      let richMessage = fields["rich_message"] as? [String: Any]
      let markdown = richMessage?["markdown"] as? String ?? ""
      if markdown.contains("Root ") || markdown.contains("preview:") {
        secretFrames.append(markdown.replacingOccurrences(of: "\\", with: ""))
      }
      if markdown.contains("Root ") {
        secretExplanation.open()
      }
      if markdown.contains("preview:") {
        secretPreview.open()
      }
      if markdown.contains("tg-thinking") {
        progressDrafts.open()
      }
      if markdown.contains(ProgressCompositionProvider.answerText) {
        answerDrafts.open()
      }
    }
  }
}

private actor ProgressCompositionProvider: LLMProvider {
  static let answerText = "composed answer"
  nonisolated let started = AsyncGate()
  nonisolated let answer = AsyncGate()
  nonisolated let finish = AsyncGate()
  private(set) var request: ChatRequest?

  func complete(request: ChatRequest) async -> ChatResponse {
    self.request = request
    started.open()
    await finish.wait()
    return okResponse(content: Self.answerText)
  }

  nonisolated func stream(request: ChatRequest) -> LLMEventStream {
    LLMEventStream.make { sink in
      await self.play(request, sink: sink)
    }
  }

}

// MARK: - Provider Script

private extension ProgressCompositionProvider {
  func play(_ request: ChatRequest, sink: LLMEventSink) async -> LLMStreamTermination {
    self.request = request
    started.open()
    await answer.wait()
    do {
      try await sink.sendDelta(Self.answerText)
      await finish.wait()
      return .completed(okResponse(content: Self.answerText))
    } catch {
      return .cancelled(.mayHaveStarted(observing: 0))
    }
  }
}

// MARK: - Secret Progress Script

private actor SecretProgressProvider: LLMProvider {
  static let rootSecret = "ordinary-root-progress-secret"
  static let mcpSecret = "mcp-only-" + String(repeating: "credential", count: 20)
  nonisolated let toolRound = AsyncGate()
  nonisolated let finish = AsyncGate()
  private var calls = 0

  func complete(request: ChatRequest) async -> ChatResponse {
    await finish.wait()
    return okResponse()
  }

  nonisolated func stream(request: ChatRequest) -> LLMEventStream {
    LLMEventStream.make { sink in
      await self.play(sink)
    }
  }

}

// MARK: - Secret Progress Rounds

private extension SecretProgressProvider {
  func play(_ sink: LLMEventSink) async -> LLMStreamTermination {
    calls += 1
    if calls > 1 {
      await finish.wait()
      return .completed(okResponse())
    }
    do {
      try await sink.sendProgress(
        LLMProgressEvent(
          itemID: "secrets",
          kind: .commentary,
          text: .replace("Root \(Self.rootSecret); MCP \(Self.mcpSecret)")
        )
      )
      try await sink.sendProgress(
        LLMProgressEvent(itemID: "secrets", kind: .commentary, text: .complete)
      )
      await toolRound.wait()
      return .completed(
        toolCallResponse([
          ToolCall(
            id: "query",
            name: "web_search",
            argumentsJSON: "{\"query\":\"preview: \(Self.mcpSecret)\"}"
          ),
        ])
      )
    } catch {
      return .cancelled(.mayHaveStarted(observing: 0))
    }
  }
}
