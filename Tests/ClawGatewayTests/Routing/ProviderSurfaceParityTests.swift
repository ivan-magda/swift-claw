import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

/// The heart of Task 26: one provider failure must produce identical owner copy and identical
/// accounting on both the interactive turn path and the schedule-drafting path. One
/// request-recording provider drives a turn and a scheduled parse; both are asserted to get the same
/// treatment, to share the one trace formatter, and to split the wire model from the accounting
/// identity.
@Suite struct ProviderSurfaceParityTests {
  private static let draftJSON = """
    {"label":"morning digest","prompt":"Summarize my unread items",\
    "schedule":{"kind":"weekdays","time":"07:00","timezone":"Europe/Berlin"}}
    """

  private static let expectedDraft = ScheduleDraft(
    label: "morning digest",
    prompt: "Summarize my unread items",
    schedule: DraftSchedule(kind: .weekdays, time: "07:00", timezone: "Europe/Berlin")
  )

  /// The spec's exact recovery sentence, copied here as an independent literal so a reword of the
  /// constant that still contains `clawd auth login` is caught rather than mirrored.
  private static let specAuthSentence =
    "ChatGPT authentication is required. Stop clawd, run `clawd auth login`, then start clawd again."

  private func userBuildResult() -> BuildResult {
    BuildResult(
      messages: [ChatMessage(role: .user, content: "hi")],
      ownerNotices: [],
      hasPrivateDataAccess: false
    )
  }

  private func makeAgent(
    provider: any LLMProvider,
    usageStore: any UsageStore,
    wireModel: String = "test-model",
    configuredReference: String = "test-model",
    costPolicy: LLMCostPolicy = .metered
  ) -> AgentRuntime {
    AgentRuntime(
      roster: makeSingleRouteRoster(
        provider: provider,
        wireModel: wireModel,
        configuredReference: configuredReference,
        costPolicy: costPolicy
      ),
      typingIndicator: NoopTyping(),
      draftStreamer: NoopRichDraftStreaming(),
      streamingEnabled: false,
      costResolver: CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015),
      budget: .default,
      toolDispatcher: nil,
      usageStore: usageStore,
      auditLog: RecordingAuditLog(),
      clock: ContinuousClock()
    )
  }

  private func makeParser(
    provider: any LLMProvider,
    usageStore: any UsageStore,
    wireModel: String = "test-model",
    configuredReference: String = "test-model",
    costPolicy: LLMCostPolicy = .metered
  ) -> ScheduleDraftParser {
    ScheduleDraftParser(
      roster: makeSingleRouteRoster(
        provider: provider,
        wireModel: wireModel,
        configuredReference: configuredReference,
        costPolicy: costPolicy
      ),
      usageStore: usageStore,
      budget: .default,
      costResolver: CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015),
      clock: ContinuousClock(),
      logger: TestLog.silent
    )
  }

  /// A two-route parser, so a quota rejection on the primary can be proven to fall back rather than
  /// degrade — the schedule twin of `AgentTestSupport.makeRuntime`'s primary/fallback pairing.
  private func makeParser(
    primary: any LLMProvider,
    fallback: any LLMProvider,
    usageStore: any UsageStore,
    cooldown: (any PrimaryRouteCooldownTracking)? = nil
  ) -> ScheduleDraftParser {
    ScheduleDraftParser(
      roster: ProviderRoster(
        primary: LLMRouteBinding(
          provider: primary,
          wireModel: "primary-wire",
          configuredReference: "primary-model",
          costPolicy: .metered,
          reservationPolicy: .textOnly
        ),
        fallback: LLMRouteBinding(
          provider: fallback,
          wireModel: "fallback-wire",
          configuredReference: "fallback-model",
          costPolicy: .metered,
          reservationPolicy: .textOnly
        )
      ),
      cooldown: cooldown,
      usageStore: usageStore,
      budget: .default,
      costResolver: CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015),
      clock: ContinuousClock(),
      logger: TestLog.silent
    )
  }

  private func claimSession(_ queue: DatabaseQueue) throws -> Int64 {
    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: "tg:dm:7",
        chatId: 7,
        userId: 7,
        text: "/schedule",
        isEdited: false,
        ts: Date()
      )
    )
    return claim.sessionId ?? 0
  }

  private func inMemoryQueue() throws -> DatabaseQueue {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return queue
  }

  private func usageRowCount(_ queue: DatabaseQueue) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage") ?? -1
    }
  }

  @Test func authSentenceMatchesTheSpecCopyByteForByte() {
    // given / when / then — the shared constant is the spec sentence verbatim, not merely a string
    // that contains the recovery command; pinned to the literal, drift in either direction fails
    #expect(Degradation.authenticationRequired == Self.specAuthSentence)
  }

  @Test func sameAuthFailureGivesIdenticalCopyAndNoDebitOnBothSurfaces() async throws {
    // given — one refused-credential failure driving a turn and a scheduled parse
    let turnQueue = try inMemoryQueue()
    let parseQueue = try inMemoryQueue()
    let turnUsage = UsageStoreGRDB(writer: turnQueue)
    let parseUsage = UsageStoreGRDB(writer: parseQueue)
    let agent = makeAgent(
      provider: SequenceProvider([], then: ProviderError.authenticationRequired),
      usageStore: turnUsage
    )
    let parser = makeParser(
      provider: SequenceProvider([], then: ProviderError.authenticationRequired),
      usageStore: parseUsage
    )
    let parseSession = try claimSession(parseQueue)

    // when
    let turnOutcome = try await agent.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: userBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )
    let parseResult = await parser.parse(ownerText: "x", sessionId: parseSession)

    // then — both carry the SAME vendor-neutral failure rather than collapsing to a generic outage
    #expect(turnOutcome.result == .degraded(.authenticationRequired, usage: nil))
    #expect(parseResult == .authenticationRequired)

    // and — the two copy homes render the one pinned login sentence, byte-identical
    #expect(
      Degradation.message(for: .authenticationRequired) == ScheduleReplies.authenticationRequired
    )
    #expect(Degradation.message(for: .authenticationRequired) == Degradation.authenticationRequired)
    #expect(Degradation.authenticationRequired.contains("clawd auth login"))

    // and — neither surface debits a proven not-started rejection
    #expect(try turnUsage.todayTokensAndCost(now: Date()).tokens == 0)
    #expect(try usageRowCount(parseQueue) == 0)
  }

  @Test func quotaFailureGivesIdenticalRetryCopyThatNeverSaysLoginOnBothSurfaces() async throws {
    // given
    let turnQueue = try inMemoryQueue()
    let parseQueue = try inMemoryQueue()
    let agent = makeAgent(
      provider: SequenceProvider([], then: ProviderError.quotaLimited(retryAfterSeconds: 30)),
      usageStore: UsageStoreGRDB(writer: turnQueue)
    )
    let parser = makeParser(
      provider: SequenceProvider([], then: ProviderError.quotaLimited(retryAfterSeconds: 30)),
      usageStore: UsageStoreGRDB(writer: parseQueue)
    )
    let parseSession = try claimSession(parseQueue)

    // when
    let turnOutcome = try await agent.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: userBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )
    let parseResult = await parser.parse(ownerText: "x", sessionId: parseSession)

    // then — the bounded hint rides both surfaces, and the copy names retry, never login
    #expect(turnOutcome.result == .degraded(.quotaLimited(retryAfterSeconds: 30), usage: nil))
    #expect(parseResult == .quotaLimited(retryAfterSeconds: 30))
    let copy = Degradation.quotaLimited(retryAfterSeconds: 30)
    #expect(copy == ScheduleReplies.quotaLimited(retryAfterSeconds: 30))
    #expect(copy.contains("30"))
    #expect(copy.contains("clawd auth login") == false)
  }

  @Test("a quota rejection on the primary parses the draft on the fallback")
  func scheduleParseFallsBack() async throws {
    // given
    let queue = try inMemoryQueue()
    let usageStore = UsageStoreGRDB(writer: queue)
    let sessionId = try claimSession(queue)
    let primary = SequenceProvider([], then: ProviderError.quotaLimited(retryAfterSeconds: nil))
    let fallback = SequenceProvider([
      ChatResponse(content: Self.draftJSON, finishReason: "stop", usage: nil, costFromProvider: nil)
    ])
    let parser = makeParser(primary: primary, fallback: fallback, usageStore: usageStore)

    // when
    let result = await parser.parse(ownerText: "every weekday at 7am Berlin", sessionId: sessionId)

    // then
    #expect(result == .draft(Self.expectedDraft))
    #expect(await fallback.requests.count == 1)
  }

  @Test("a successful parse on a recovered primary clears its cooldown window")
  func successfulParseClearsTheRecoveredPrimarysCooldown() async throws {
    // given — the primary armed a long window, then it lapses without ever being cleared
    let cooldownClock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: cooldownClock)
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)
    try await cooldownClock.sleep(for: .seconds(901))
    let queue = try inMemoryQueue()
    let usageStore = UsageStoreGRDB(writer: queue)
    let sessionId = try claimSession(queue)
    let primary = SequenceProvider([
      ChatResponse(content: Self.draftJSON, finishReason: "stop", usage: nil, costFromProvider: nil)
    ])
    let parser = makeParser(
      primary: primary,
      fallback: SequenceProvider([]),
      usageStore: usageStore,
      cooldown: cooldown
    )

    // when — the recovered primary answers
    let result = await parser.parse(ownerText: "every weekday at 7am", sessionId: sessionId)

    // then — the window is cleared, not merely lapsed: a fresh arm starts at the tier default
    // rather than doubling the stale armed duration a lapsed-but-uncleared window would carry
    #expect(result == .draft(Self.expectedDraft))
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)
    #expect(await cooldown.remainingSeconds() == 900)
  }

  @Test("a fallback that also fails still reports the primary's actionable cause")
  func doubleFailureReportsThePrimarysCause() async throws {
    // given — the primary's quota is out (switchable), then the fallback can't even connect
    // (also switchable, but there is no third route to try)
    let queue = try inMemoryQueue()
    let usageStore = UsageStoreGRDB(writer: queue)
    let sessionId = try claimSession(queue)
    let primary = SequenceProvider([], then: ProviderError.quotaLimited(retryAfterSeconds: 42))
    let fallback = SequenceProvider([], then: ProviderError.connectFailed(message: "down"))
    let parser = makeParser(primary: primary, fallback: fallback, usageStore: usageStore)

    // when
    let result = await parser.parse(ownerText: "x", sessionId: sessionId)

    // then — the primary's actionable "quota limited" survives, not the fallback's generic outage
    #expect(result == .quotaLimited(retryAfterSeconds: 42))
    #expect(
      ScheduleReplies.providerFailure(result) == ScheduleReplies.quotaLimited(retryAfterSeconds: 42)
    )
  }

  @Test("turn and schedule paths still produce identical copy for one cause")
  func parityHoldsWithARoster() async throws {
    // given a single-route roster on both paths
    let turnQueue = try inMemoryQueue()
    let parseQueue = try inMemoryQueue()
    let agent = makeAgent(
      provider: SequenceProvider([], then: ProviderError.quotaLimited(retryAfterSeconds: 42)),
      usageStore: UsageStoreGRDB(writer: turnQueue)
    )
    let parser = makeParser(
      provider: SequenceProvider([], then: ProviderError.quotaLimited(retryAfterSeconds: 42)),
      usageStore: UsageStoreGRDB(writer: parseQueue)
    )
    let parseSession = try claimSession(parseQueue)

    // when both fail with .quotaLimited(retryAfterSeconds: 42)
    let turnOutcome = try await agent.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: userBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )
    let parseResult = await parser.parse(ownerText: "x", sessionId: parseSession)

    // then both replies equal Degradation.quotaLimited(retryAfterSeconds: 42)
    #expect(turnOutcome.result == .degraded(.quotaLimited(retryAfterSeconds: 42), usage: nil))
    #expect(parseResult == .quotaLimited(retryAfterSeconds: 42))
    let copy = Degradation.quotaLimited(retryAfterSeconds: 42)
    #expect(copy == ScheduleReplies.quotaLimited(retryAfterSeconds: 42))
  }

  @Test func bothSurfacesShareTheTraceFormatterAndSplitWireModelFromIdentity() async throws {
    // given — a recording provider that succeeds, so each surface's request and usage row are visible
    let wireModel = "wire-model"
    let identity = "identity-ref"
    let turnProvider = SequenceProvider([
      ChatResponse(
        content: "ok",
        finishReason: "stop",
        usage: ChatUsage(promptTokens: 5, completionTokens: 3, totalTokens: 8),
        costFromProvider: 0.001
      )
    ])
    let parseProvider = SequenceProvider([
      ChatResponse(
        content: Self.draftJSON,
        finishReason: "stop",
        usage: ChatUsage(promptTokens: 7, completionTokens: 4, totalTokens: 11),
        costFromProvider: 0.002
      )
    ])
    let parseQueue = try inMemoryQueue()
    let agent = makeAgent(
      provider: turnProvider,
      usageStore: UsageStoreGRDB(writer: try inMemoryQueue()),
      wireModel: wireModel,
      configuredReference: identity
    )
    let parser = makeParser(
      provider: parseProvider,
      usageStore: UsageStoreGRDB(writer: parseQueue),
      wireModel: wireModel,
      configuredReference: identity
    )
    let turnSession: Int64 = 77
    let parseSession = try claimSession(parseQueue)

    // when
    let turnOutcome = try await agent.runTurn(
      runId: 1,
      sessionId: turnSession,
      chatId: 3,
      buildResult: userBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )
    let parseResult = await parser.parse(ownerText: "x", sessionId: parseSession)

    // then — both requests stamp the one shared trace identity, keyed on the database session id
    let turnRequest = try #require(await turnProvider.requests.first)
    let parseRequest = try #require(await parseProvider.requests.first)
    #expect(turnRequest.sessionId == SessionTraceID.format(sessionID: turnSession))
    #expect(parseRequest.sessionId == SessionTraceID.format(sessionID: parseSession))

    // and — the wire model crosses the wire on both; the configured identity is used only for usage
    #expect(turnRequest.model == wireModel)
    #expect(parseRequest.model == wireModel)
    #expect(parseResult == .draft(Self.expectedDraft))

    guard case .completed(_, let turnUsage, _) = turnOutcome.result else {
      Issue.record("expected a completed turn, got \(turnOutcome.result)")
      return
    }
    #expect(turnUsage.model == identity)
    let parseModel = try await parseQueue.read { db in
      try String.fetchOne(db, sql: "SELECT model FROM provider_usage")
    }
    #expect(parseModel == identity)
  }

  @Test func noPrivateSessionTraceFormatterRemains() throws {
    // given — the one legitimate home for the `clawd-session-` prefix
    let sourcesRoot = Self.repoRoot().appendingPathComponent("Sources")

    // when — every source file except the shared formatter is scanned for the raw prefix
    let offenders = try Self.swiftFiles(under: sourcesRoot).filter { url in
      guard url.lastPathComponent != "SessionTraceID.swift" else {
        return false
      }
      let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      return contents.contains("clawd-session-")
    }

    // then — no second, private formatter has re-opened the split trace identity
    #expect(offenders.isEmpty, "private clawd-session- formatter(s): \(offenders.map(\.path))")
  }
}

// MARK: - Source Guard Support

private extension ProviderSurfaceParityTests {
  /// The repository root, four directories up from this file
  /// (`Tests/ClawGatewayTests/Routing/<file>`).
  static func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Routing
      .deletingLastPathComponent()  // ClawGatewayTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
  }

  static func swiftFiles(under root: URL) throws -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
      )
    else {
      return []
    }
    var files: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      files.append(url)
    }
    return files
  }
}
