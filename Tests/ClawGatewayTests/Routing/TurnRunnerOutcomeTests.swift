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
      provider: provider,
      typingIndicator: NoopTyping(),
      draftStreamer: NoopRichDraftStreaming(),
      streamingEnabled: false,
      costResolver: CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015),
      budget: budget,
      model: "test-model",
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
      notifyOutbox: {},
      // Inert on purpose: these fixtures never resolve approvals, so no turn may reach a park.
      parker: InertApprovalParker(coordinator: ApprovalCoordinator()),
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
}
