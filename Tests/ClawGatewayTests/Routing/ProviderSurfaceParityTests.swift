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
      provider: provider,
      typingIndicator: NoopTyping(),
      draftStreamer: NoopRichDraftStreaming(),
      streamingEnabled: false,
      costResolver: CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015),
      budget: .default,
      wireModel: wireModel,
      configuredReference: configuredReference,
      costPolicy: costPolicy,
      reservationPolicy: .textOnly,
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
      provider: provider,
      wireModel: wireModel,
      configuredReference: configuredReference,
      usageStore: usageStore,
      budget: .default,
      costResolver: CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015),
      costPolicy: costPolicy,
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

  @Test func sameAuthFailureGivesIdenticalCopyAndNoDebitOnBothSurfaces() async throws {
    // given — one refused-credential failure driving a turn and a scheduled parse
    let turnQueue = try inMemoryQueue()
    let parseQueue = try inMemoryQueue()
    let turnUsage = UsageStoreGRDB(writer: turnQueue)
    let parseUsage = UsageStoreGRDB(writer: parseQueue)
    let agent = makeAgent(provider: FailingProvider(.authenticationRequired), usageStore: turnUsage)
    let parser = makeParser(
      provider: FailingProvider(.authenticationRequired),
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
      provider: FailingProvider(.quotaLimited(retryAfterSeconds: 30)),
      usageStore: UsageStoreGRDB(writer: turnQueue)
    )
    let parser = makeParser(
      provider: FailingProvider(.quotaLimited(retryAfterSeconds: 30)),
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
