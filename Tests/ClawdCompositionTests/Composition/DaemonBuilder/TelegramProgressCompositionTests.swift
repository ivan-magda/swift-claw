import ClawAgent
import ClawData
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
    if scenario.expectsAnswer {
      #expect(await signals.answerDrafts.waitUntilOpen())
    }
    provider.finish.open()
    try await task.value

    // then
    let requests = await http.recorded
    let draftBodies = requests.filter { $0.url.hasSuffix("/sendRichMessageDraft") }
      .map(\.body).compactMap { String(data: $0, encoding: .utf8) }
    #expect(draftBodies.contains { $0.contains("tg-thinking") } == scenario.expectsProgress)
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
    provider: ProgressCompositionProvider
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
    let builder = try CompositionAcceptance.makeBuilder(http: http, config: config)
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
      presentationClock: ScriptedClock.compressed(parkingAt: .seconds(1))
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
      learning: nil
    )
    let runner = builder.makeTurnRunner(
      coordination: coordination,
      agentStack: stack,
      costPolicy: roster.primary.costPolicy,
      imageCache: ImageCache(),
      freezeLearningSurface: { _, _ in }
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
  private(set) var typingTargets: [DeliveryTarget] = []

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
      let markdown = String(data: request.body ?? Data(), encoding: .utf8) ?? ""
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
