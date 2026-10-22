import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

@Suite
struct TurnRunnerOutcomeTests {
  private struct Fixture {
    let runner: TurnRunner
    let stores: ClawStores
    let sessionID: Int64
    let runID: Int64
    let triggerMessageID: Int64
    let databasePath: String
  }

  /// Real temp-file SQLite (spec §17) so taint persistence can be asserted across a re-open.
  private func makeFixture(
    provider: any LLMProvider,
    dispatcher: (any ToolDispatching)?,
    budget: RunBudget = .default
  ) throws -> Fixture {
    let databasePath = FileManager.default.temporaryDirectory.appendingPathComponent(
      "claw-sc3-\(UUID().uuidString).sqlite"
    ).path
    let stores = try ClawDatabase.openStores(path: databasePath)
    let claim = try stores.sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: 7),
        chatID: 7,
        userID: 7,
        text: "read https://example.com/a and summarize",
        isEdited: false,
        journalAdmission: nil,
        ts: Date()
      )
    )
    let agent = AgentRuntime(
      roster: makeSingleRouteRoster(provider: provider, wireModel: "test-model"),
      typingIndicator: NoopTyping(),
      draftStreamer: NoopRichDraftStreaming(),
      streamingEnabled: false,
      costResolver: CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015),
      budget: budget,
      toolDispatcher: dispatcher,
      usageStore: stores.usage,
      auditLog: stores.audit,
      clock: ContinuousClock()
    )
    let runner = TurnRunner(
      sessionMessages: stores.sessionMessages,
      runs: stores.runs,
      usageStore: stores.usage,
      audit: stores.audit,
      agent: agent,
      contextBuilder: makeEmptyContextBuilder(),
      imageCache: ImageCache(),
      notifyOutbox: {},
      // Inert on purpose: these fixtures never resolve approvals, so no turn may reach a park.
      parker: InertApprovalParker(coordinator: ApprovalCoordinator()),
      approvalExpirySeconds: testApprovalExpirySeconds,
      journalCapture: nil,
      notifyJournal: {},
      logger: TestLog.silent
    )
    return Fixture(
      runner: runner,
      stores: stores,
      sessionID: claim.sessionID ?? 0,
      runID: claim.runID ?? 0,
      triggerMessageID: claim.triggerMessageID ?? 0,
      databasePath: databasePath
    )
  }

  private func outboxPayloads(_ fixture: Fixture) throws -> [String] {
    try fixture.stores.outbox.pendingOutbound().map(\.payload)
  }

  /// Transitions the fixture's run PENDING → RUNNING (what `run()` does at pickup) and commits a
  /// hand-built `TurnOutcome` directly. The outcome-mapping tests below only care about the
  /// notice-to-copy mapping, not how a real turn arrives at that outcome — the switching mechanics
  /// themselves are already covered by `AgentRuntimeFallbackTests`.
  private func runCommit(_ fixture: Fixture, _ outcome: TurnOutcome) async throws -> String {
    _ = try fixture.stores.runs.pickUp(runID: fixture.runID, policyVersion: nil, now: Date())
    try await fixture.runner.commit(
      outcome,
      runID: fixture.runID,
      sessionID: fixture.sessionID,
      chatID: 7,
      mode: .direct,
      ownerNotices: [],
      origin: .interactive
    )
    return try outboxPayloads(fixture).joined(separator: "\n\n")
  }

  @Test
  func completedToolTurnPersistsExchangesTaintAndUsageRows() async throws {
    // given — one tool round-trip then an answer
    let fixture = try makeFixture(
      provider: SequenceProvider([
        toolCallResponse([fetchProposal()]),
        okResponse(content: "summary of the page"),
      ]),
      dispatcher: ScriptedDispatcher(respond: okOutcome(content: "page text"))
    )

    // when
    try await fixture.runner.run(
      runID: fixture.runID,
      sessionID: fixture.sessionID,
      chatID: 7,
      triggerMessageID: fixture.triggerMessageID
    )

    // then — reply delivered; exchange rows + taint persisted (REOPEN the DB to assert, §17-1)
    #expect(
      try outboxPayloads(fixture).contains { payload in
        payload.contains("summary of the page")
      }
    )
    let reopened = try ClawDatabase.openStores(path: fixture.databasePath)
    let snapshot = try reopened.sessionMessages.loadContextSnapshot(
      sessionID: fixture.sessionID,
      throughMessageID: Int64.max,
      limit: 50
    )
    #expect(snapshot.isTainted)
    #expect(
      snapshot.history.contains { stored in
        stored.role == .tool
      }
    )
    // two usage rows: the intermediate write + the commit-borne final row (D6)
    let totals = try reopened.usage.todayTokensAndCost(now: Date())
    #expect(totals.tokens > 0)
  }

  @Test
  func degradedRunPersistsItsExecutedExchanges() async throws {
    // given — round-trip 1 executes one tool; round-trip 2 is unscripted, so the provider throws
    // terminal and the run degrades. The executed exchange must survive the failure commit.
    let provider = SequenceProvider([
      ChatResponse(
        content: "",
        finishReason: "tool_calls",
        usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
        costFromProvider: 0.001,
        toolCalls: [
          ToolCall(id: "c1", name: "web_fetch", argumentsJSON: #"{"url":"https://e.example/"}"#),
        ]
      ),
    ])
    let dispatcher = ScriptedDispatcher(respond: okOutcome())
    let fixture = try makeFixture(provider: provider, dispatcher: dispatcher)

    // when
    try await fixture.runner.run(
      runID: fixture.runID,
      sessionID: fixture.sessionID,
      chatID: 7,
      triggerMessageID: fixture.triggerMessageID
    )

    // then — the run FAILED, yet the anchor + observation rows exist in durable history
    let queue = try DatabaseQueue(path: fixture.databasePath)
    let toolRows = try await queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE role = 'tool'") ?? -1
    }
    #expect(toolRows == 1)
    let runState = try await queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT state FROM runs WHERE id = ?",
        arguments: [fixture.runID]
      )
    }
    #expect(runState == RunState.failed.rawValue)
  }

  @Test
  func budgetStoppedTurnStillTaints() async throws {
    // given — c1 executes (untrusted ingestion), then the per-run tool-call cap ends the run at c2
    // (rev.1 L4). maxToolCalls 1 makes the second proposal in the same batch trip the cap.
    let smallBudget = RunBudget(
      maxInputTokens: 100_000,
      maxOutputTokens: 4_096,
      wallClockDeadlineSeconds: 180,
      retryBudget: 3,
      perRunUSD: 0.50,
      perDayUSD: 10,
      proactivePerDayUSD: 2.00,
      referenceUSDPerToken: 0.000_015,
      maxTurns: 12,
      maxToolCalls: 1
    )
    let fixture = try makeFixture(
      provider: SequenceProvider([
        toolCallResponse([fetchProposal(id: "c1"), fetchProposal(id: "c2")]),
      ]),
      dispatcher: ScriptedDispatcher(respond: okOutcome()),
      budget: smallBudget
    )

    // when
    try await fixture.runner.run(
      runID: fixture.runID,
      sessionID: fixture.sessionID,
      chatID: 7,
      triggerMessageID: fixture.triggerMessageID
    )

    // then — the run FAILED with the named-cap reply (`Degradation.budget(cap:)`), and the taint
    // from c1's ingestion persisted even though the budget-stopped commit dropped the exchanges (§10).
    let payloads = try outboxPayloads(fixture)
    #expect(
      payloads.contains { payload in
        payload.contains(BudgetGate.perRunToolCallCap)
      }
    )
    let snapshot = try fixture.stores.sessionMessages.loadContextSnapshot(
      sessionID: fixture.sessionID,
      throughMessageID: Int64.max,
      limit: 50
    )
    #expect(snapshot.isTainted)
  }

  @Test(arguments: [
    (ProviderError.authenticationRequired, Degradation.authenticationRequired),
    (.quotaLimited(retryAfterSeconds: 30), Degradation.quotaLimited(retryAfterSeconds: 30)),
    (.accessDenied, Degradation.accessDenied),
    (.invalidProviderState, Degradation.invalidProviderState),
  ])
  func aNotStartedProviderFailureDeliversItsOwnCopyAndDebitsNothing(
    failure: ProviderError,
    expectedPayload: String
  ) async throws {
    // given — the provider refuses before any inference begins (a clean, not-started head)
    let fixture = try makeFixture(provider: SequenceProvider([], then: failure), dispatcher: nil)

    // when
    try await fixture.runner.run(
      runID: fixture.runID,
      sessionID: fixture.sessionID,
      chatID: 7,
      triggerMessageID: fixture.triggerMessageID
    )

    // then — each failure reaches the owner as its own pinned copy (a cross-mapping, such as an
    // access denial telling the owner to log in, fails here), and no usage row was written
    let payloads = try outboxPayloads(fixture)
    #expect(payloads.contains(expectedPayload))
    #expect(try fixture.stores.usage.todayTokensAndCost(now: Date()).tokens == 0)
  }

  /// One route-notice mapping: the committed result, the notice riding it, and the exact outbox
  /// text. A `.completed` result needs a usage row bound to the fixture's session, so each case
  /// builds its result from that session.
  struct RouteNoticeCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let result: @Sendable (_ sessionID: Int64) -> TurnResult
    let routeNotice: RouteNotice?
    let expected: String
  }

  private static let primaryRoute = "openai-chatgpt/gpt-5.4"
  private static let fallbackRoute = "gpt-5.4"
  private static let answered: @Sendable (_ sessionID: Int64) -> TurnResult = { sessionID in
    .completed(content: "answer", usage: usageFixture(sessionID: sessionID), providerState: nil)
  }

  static let routeNoticeCases = [
    RouteNoticeCase(
      testDescription: "a switched turn appends the route notice to the reply",
      result: answered,
      routeNotice: .switched(from: primaryRoute, to: fallbackRoute),
      expected: "answer\n\n"
        + Degradation.routeSwitched(from: primaryRoute, to: fallbackRoute)
    ),
    RouteNoticeCase(
      testDescription: "a turn with no route notice sends the reply unchanged",
      result: answered,
      routeNotice: nil,
      expected: "answer"
    ),
    RouteNoticeCase(
      testDescription: "a restored turn tells the owner the primary is answering again",
      result: answered,
      routeNotice: .restored(route: primaryRoute),
      expected: "answer\n\n\(Degradation.routeRestored(route: primaryRoute))"
    ),
    // The combination task 7 left as this task's signal: a non-nil switch notice riding a
    // `.degraded` result.
    RouteNoticeCase(
      testDescription: "a switch that also fails tells the owner the backup was tried too",
      result: { _ in
        .degraded(.providerUnavailable, usage: nil)
      },
      routeNotice: .switched(from: primaryRoute, to: fallbackRoute),
      expected: "\(Degradation.providerUnavailable)\n\n\(Degradation.fallbackAlsoFailed)"
    ),
    // `.restored` means the primary alone answered this round, so "I tried the backup model too"
    // would be false; only a `.switched` notice earns that sentence.
    RouteNoticeCase(
      testDescription: "a restored turn that still degrades does not claim a backup was tried",
      result: { _ in
        .degraded(.outputTruncated, usage: nil)
      },
      routeNotice: .restored(route: primaryRoute),
      expected: Degradation.outputTruncated
    ),
    // `routeNotice` is turn-scoped: a switch earlier this turn is still owed to the owner even
    // though the round that tripped the cap produced no answer.
    RouteNoticeCase(
      testDescription: "a budget-stopped turn that already switched still tells the owner",
      result: { _ in
        .budgetStopped(cap: BudgetGate.perRunToolCallCap)
      },
      routeNotice: .switched(from: primaryRoute, to: fallbackRoute),
      expected: "\(Degradation.budget(cap: BudgetGate.perRunToolCallCap))\n\n"
        + "\(Degradation.routeSwitched(from: primaryRoute, to: fallbackRoute))"
    ),
    RouteNoticeCase(
      testDescription: "a budget-stopped turn with no route notice sends the reply unchanged",
      result: { _ in
        .budgetStopped(cap: BudgetGate.perRunToolCallCap)
      },
      routeNotice: nil,
      expected: Degradation.budget(cap: BudgetGate.perRunToolCallCap)
    ),
  ]

  @Test(arguments: routeNoticeCases)
  func aRouteNoticeMapsToItsExactOwnerCopy(_ testCase: RouteNoticeCase) async throws {
    // given
    let fixture = try makeFixture(provider: SequenceProvider([]), dispatcher: nil)
    let outcome = TurnOutcome(
      result: testCase.result(fixture.sessionID),
      routeNotice: testCase.routeNotice
    )

    // when
    let sent = try await runCommit(fixture, outcome)

    // then
    #expect(sent == testCase.expected)
  }

  @Test("a refusal on a guessed price names the model the owner has to price")
  func budgetStoppedOnAGuessedPriceNamesTheModel() async throws {
    // given
    let fixture = try makeFixture(provider: SequenceProvider([]), dispatcher: nil)
    let outcome = TurnOutcome(
      result: .budgetStopped(cap: BudgetGate.perRunSpendCap, unpricedModel: "vendor/new-model"),
      routeNotice: nil
    )

    // when
    let sent = try await runCommit(fixture, outcome)

    // then — the owner learns which model to price, not only which cap tripped
    #expect(sent.hasPrefix(Degradation.budget(cap: BudgetGate.perRunSpendCap)))
    #expect(sent.contains("vendor/new-model"))
  }
}
