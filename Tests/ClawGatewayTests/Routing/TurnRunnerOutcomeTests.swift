import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

@Suite struct TurnRunnerOutcomeTests {
  private struct Fixture {
    let runner: TurnRunner
    let stores: ClawStores
    let sessionId: Int64
    let runId: Int64
    let triggerMessageId: Int64
    let databasePath: String
  }

  /// Real temp-file SQLite (spec §17) so taint persistence can be asserted across a re-open.
  private func makeFixture(
    provider: any LLMProvider,
    dispatcher: (any ToolDispatching)?,
    budget: RunBudget = .default
  ) throws -> Fixture {
    let databasePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-sc3-\(UUID().uuidString).sqlite").path
    let stores = try ClawDatabase.openStores(path: databasePath)
    let claim = try stores.sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 7),
        chatId: 7,
        userId: 7,
        text: "read https://example.com/a and summarize",
        isEdited: false,
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
      budget: budget,
      contextBuilder: makeEmptyContextBuilder(),
      imageCache: ImageCache(),
      notifyOutbox: {},
      // Inert on purpose: these fixtures never resolve approvals, so no turn may reach a park.
      parker: InertApprovalParker(coordinator: ApprovalCoordinator()),
      approvalExpirySeconds: testApprovalExpirySeconds,
      logger: TestLog.silent
    )
    return Fixture(
      runner: runner,
      stores: stores,
      sessionId: claim.sessionId ?? 0,
      runId: claim.runId ?? 0,
      triggerMessageId: claim.triggerMessageId ?? 0,
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
    _ = try fixture.stores.runs.pickUp(runId: fixture.runId, policyVersion: nil, now: Date())
    try await fixture.runner.commit(
      outcome,
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      ownerNotices: [],
      origin: .interactive
    )
    return try outboxPayloads(fixture).joined(separator: "\n\n")
  }

  @Test func completedToolTurnPersistsExchangesTaintAndUsageRows() async throws {
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
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      triggerMessageId: fixture.triggerMessageId
    )

    // then — reply delivered; exchange rows + taint persisted (REOPEN the DB to assert, §17-1)
    #expect(
      try outboxPayloads(fixture).contains { payload in payload.contains("summary of the page") }
    )
    let reopened = try ClawDatabase.openStores(path: fixture.databasePath)
    let snapshot = try reopened.sessionMessages.loadContextSnapshot(
      sessionId: fixture.sessionId,
      throughMessageId: Int64.max,
      limit: 50
    )
    #expect(snapshot.isTainted)
    #expect(snapshot.history.contains { stored in stored.role == .tool })
    // two usage rows: the intermediate write + the commit-borne final row (D6)
    let totals = try reopened.usage.todayTokensAndCost(now: Date())
    #expect(totals.tokens > 0)
  }

  @Test func degradedRunPersistsItsExecutedExchanges() async throws {
    // given — round-trip 1 executes one tool; round-trip 2 is unscripted, so the provider throws
    // terminal and the run degrades. The executed exchange must survive the failure commit.
    let provider = SequenceProvider([
      ChatResponse(
        content: "",
        finishReason: "tool_calls",
        usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
        costFromProvider: 0.001,
        toolCalls: [
          ToolCall(id: "c1", name: "web_fetch", argumentsJSON: #"{"url":"https://e.example/"}"#)
        ]
      )
    ])
    let dispatcher = ScriptedDispatcher(respond: okOutcome())
    let fixture = try makeFixture(provider: provider, dispatcher: dispatcher)

    // when
    try await fixture.runner.run(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      triggerMessageId: fixture.triggerMessageId
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
        arguments: [fixture.runId]
      )
    }
    #expect(runState == RunState.failed.rawValue)
  }

  @Test func budgetStoppedTurnStillTaints() async throws {
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
        toolCallResponse([fetchProposal(id: "c1"), fetchProposal(id: "c2")])
      ]),
      dispatcher: ScriptedDispatcher(respond: okOutcome()),
      budget: smallBudget
    )

    // when
    try await fixture.runner.run(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      triggerMessageId: fixture.triggerMessageId
    )

    // then — the run FAILED with the named-cap reply (`Degradation.budget(cap:)`), and the taint
    // from c1's ingestion persisted even though the budget-stopped commit dropped the exchanges (§10).
    let payloads = try outboxPayloads(fixture)
    #expect(payloads.contains { payload in payload.contains("per-run tool-call") })
    let snapshot = try fixture.stores.sessionMessages.loadContextSnapshot(
      sessionId: fixture.sessionId,
      throughMessageId: Int64.max,
      limit: 50
    )
    #expect(snapshot.isTainted)
  }

  @Test func authenticationFailureDeliversTheExactLoginCopyAndDebitsNothing() async throws {
    // given — the credential is refused before any inference begins (a clean, not-started head)
    let fixture = try makeFixture(
      provider: SequenceProvider([], then: ProviderError.authenticationRequired),
      dispatcher: nil
    )

    // when
    try await fixture.runner.run(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      triggerMessageId: fixture.triggerMessageId
    )

    // then — the pinned login sentence reaches the owner verbatim, and no usage row was written
    let payloads = try outboxPayloads(fixture)
    #expect(payloads.contains(Degradation.authenticationRequired))
    #expect(payloads.contains { payload in payload.contains("clawd auth login") })
    #expect(try fixture.stores.usage.todayTokensAndCost(now: Date()).tokens == 0)
  }

  @Test func quotaFailureSaysRetryNotLoginAndDebitsNothing() async throws {
    // given
    let fixture = try makeFixture(
      provider: SequenceProvider([], then: ProviderError.quotaLimited(retryAfterSeconds: 30)),
      dispatcher: nil
    )

    // when
    try await fixture.runner.run(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      triggerMessageId: fixture.triggerMessageId
    )

    // then — the quota reply names the retry, never the login command, and debits nothing
    let payloads = try outboxPayloads(fixture)
    #expect(payloads.contains(Degradation.quotaLimited(retryAfterSeconds: 30)))
    #expect(payloads.allSatisfy { payload in payload.contains("clawd auth login") == false })
    #expect(try fixture.stores.usage.todayTokensAndCost(now: Date()).tokens == 0)
  }

  @Test func accessDenialDoesNotTellTheOwnerToLogIn() async throws {
    // given
    let fixture = try makeFixture(
      provider: SequenceProvider([], then: ProviderError.accessDenied),
      dispatcher: nil
    )

    // when
    try await fixture.runner.run(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      triggerMessageId: fixture.triggerMessageId
    )

    // then — the access reply never names the login recovery, and debits nothing
    let payloads = try outboxPayloads(fixture)
    #expect(payloads.contains(Degradation.accessDenied))
    #expect(payloads.allSatisfy { payload in payload.contains("clawd auth login") == false })
    #expect(try fixture.stores.usage.todayTokensAndCost(now: Date()).tokens == 0)
  }

  @Test func rejectedReplayStateGivesNewGuidanceAndDebitsNothing() async throws {
    // given
    let fixture = try makeFixture(
      provider: SequenceProvider([], then: ProviderError.invalidProviderState),
      dispatcher: nil
    )

    // when
    try await fixture.runner.run(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      triggerMessageId: fixture.triggerMessageId
    )

    // then — safe /new guidance, never a login prompt, and debits nothing
    let payloads = try outboxPayloads(fixture)
    #expect(payloads.contains(Degradation.invalidProviderState))
    #expect(payloads.contains { payload in payload.contains("/new") })
    #expect(payloads.allSatisfy { payload in payload.contains("clawd auth login") == false })
    #expect(try fixture.stores.usage.todayTokensAndCost(now: Date()).tokens == 0)
  }

  @Test("a switched turn appends the route notice to the reply")
  func switchedTurnAppendsNotice() async throws {
    // given
    let fixture = try makeFixture(provider: SequenceProvider([]), dispatcher: nil)
    let outcome = TurnOutcome(
      result: .completed(
        content: "answer",
        usage: usageFixture(sessionId: fixture.sessionId),
        providerState: nil
      ),
      routeNotice: .switched(from: "openai-chatgpt/gpt-5.4", to: "gpt-5.4")
    )

    // when
    let sent = try await runCommit(fixture, outcome)

    // then
    #expect(sent.contains("answer"))
    #expect(sent.contains("gpt-5.4"))
  }

  @Test("a turn with no route notice sends the reply unchanged")
  func unswitchedTurnIsUnchanged() async throws {
    // given
    let fixture = try makeFixture(provider: SequenceProvider([]), dispatcher: nil)
    let outcome = TurnOutcome(
      result: .completed(
        content: "answer",
        usage: usageFixture(sessionId: fixture.sessionId),
        providerState: nil
      ),
      routeNotice: nil
    )

    // when
    let sent = try await runCommit(fixture, outcome)

    // then
    #expect(sent == "answer")
  }

  @Test("a restored turn tells the owner the primary is answering again")
  func restoredTurnAppendsNotice() async throws {
    // given
    let fixture = try makeFixture(provider: SequenceProvider([]), dispatcher: nil)
    let outcome = TurnOutcome(
      result: .completed(
        content: "answer",
        usage: usageFixture(sessionId: fixture.sessionId),
        providerState: nil
      ),
      routeNotice: .restored(route: "openai-chatgpt/gpt-5.4")
    )

    // when
    let sent = try await runCommit(fixture, outcome)

    // then
    #expect(sent == "answer\n\n\(Degradation.routeRestored(route: "openai-chatgpt/gpt-5.4"))")
  }

  @Test("a switch that also fails tells the owner the backup was tried too")
  func switchedThenDegradedAppendsFallbackAlsoFailed() async throws {
    // given — the exact combination task 7 left as this task's signal: a non-nil switch notice
    // riding a `.degraded` result.
    let fixture = try makeFixture(provider: SequenceProvider([]), dispatcher: nil)
    let outcome = TurnOutcome(
      result: .degraded(.providerUnavailable, usage: nil),
      routeNotice: .switched(from: "openai-chatgpt/gpt-5.4", to: "gpt-5.4")
    )

    // when
    let sent = try await runCommit(fixture, outcome)

    // then
    #expect(sent == "\(Degradation.providerUnavailable)\n\n\(Degradation.fallbackAlsoFailed)")
  }

  @Test("a restored turn that still degrades does not claim a backup was tried")
  func restoredThenDegradedOmitsFallbackAlsoFailed() async throws {
    // given — `.restored` means the primary alone answered this round, so "I tried the backup
    // model too" would be false; only a `.switched` notice earns that sentence.
    let fixture = try makeFixture(provider: SequenceProvider([]), dispatcher: nil)
    let outcome = TurnOutcome(
      result: .degraded(.outputTruncated, usage: nil),
      routeNotice: .restored(route: "openai-chatgpt/gpt-5.4")
    )

    // when
    let sent = try await runCommit(fixture, outcome)

    // then
    #expect(sent == Degradation.outputTruncated)
  }

  @Test("a budget-stopped turn that already switched still tells the owner")
  func budgetStoppedWithSwitchAppendsNotice() async throws {
    // given — `routeNotice` is turn-scoped: a switch earlier this turn is still owed to the owner
    // even though the round that tripped the cap produced no answer.
    let fixture = try makeFixture(provider: SequenceProvider([]), dispatcher: nil)
    let outcome = TurnOutcome(
      result: .budgetStopped(cap: "per-run tool-call"),
      routeNotice: .switched(from: "openai-chatgpt/gpt-5.4", to: "gpt-5.4")
    )

    // when
    let sent = try await runCommit(fixture, outcome)

    // then
    #expect(
      sent
        == "\(Degradation.budget(cap: "per-run tool-call"))\n\n"
        + "\(Degradation.routeSwitched(from: "openai-chatgpt/gpt-5.4", to: "gpt-5.4"))"
    )
  }

  @Test("a budget-stopped turn with no route notice sends the reply unchanged")
  func budgetStoppedWithNoNoticeIsUnchanged() async throws {
    // given
    let fixture = try makeFixture(provider: SequenceProvider([]), dispatcher: nil)
    let outcome = TurnOutcome(
      result: .budgetStopped(cap: "per-run tool-call"),
      routeNotice: nil
    )

    // when
    let sent = try await runCommit(fixture, outcome)

    // then
    #expect(sent == Degradation.budget(cap: "per-run tool-call"))
  }
}
