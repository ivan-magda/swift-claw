import ClawAgent
import ClawCore
import ClawData
import ClawGateway
import ClawTestSupport
import Foundation
import GRDB
import Testing

@Suite
struct AgentRuntimeProgressTests {
  @Test
  func textThenToolsReturnsToWorkingWithoutFinishingTheRun() async throws {
    // given
    let database = try TestDatabase.make()
    let claim = try SessionMessageStoreGRDB(writer: database).claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: 99),
        chatID: 99,
        userID: 99,
        text: "weather",
        isEdited: false,
        journalAdmission: nil,
        ts: Date()
      )
    )
    let runID = try #require(claim.runID)
    let sessionID = try #require(claim.sessionID)
    let drafts = MatchingProgressDrafts()
    let provider = ProgressSequenceProvider(interimSeen: drafts.interimSeen)
    let probes = PresentationProbes()
    let registry = try makePresentations(clock: probes.clock, drafts: drafts, typing: NoopTyping())
    let scope = TurnScope(
      runID: runID,
      sessionID: sessionID,
      chatID: 99,
      threadID: nil,
      mode: .direct,
      origin: .interactive,
      requesterUserID: 99
    )
    let reporter = try #require(await registry.begin(scope: scope))
    let toolStarted = AsyncGate()
    let releaseTool = AsyncGate()
    defer {
      releaseTool.open()
      drafts.interimSeen.open()
    }
    let usage = UsageStoreGRDB(writer: database)
    let runtime = AgentRuntime(
      roster: makeSingleRouteRoster(provider: provider, wireModel: "test-model"),
      typingIndicator: NoopTyping(),
      draftStreamer: NoopRichDraftStreaming(),
      streamingEnabled: true,
      costResolver: CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015),
      budget: .default,
      toolDispatcher: progressDispatcher(
        tool: ProgressTestTool(
          started: toolStarted,
          release: releaseTool
        )
      ),
      usageStore: usage,
      auditLog: RecordingAuditLog(),
      providerCallIDGenerator: SequentialCallIDGenerator(),
      clock: ContinuousClock()
    )
    let answerPublished = AsyncGate()
    let snapshots = ProgressSnapshots()
    let request = TurnRequest(
      scope: scope,
      context: BuildResult(
        messages: [ChatMessage(role: .user, content: "weather")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      session: SessionTrust(isTainted: false, hasPrivateData: false),
      spend: SpendSnapshot(todayTokens: 0, todayUSD: 0, proactiveTodayUSD: 0, carryOver: nil),
      progress: TurnProgressReporter(explanationsEnabled: true) { event in
        await snapshots.publish(event)
        await reporter.publish(event)
        if case .answerPreview(let text) = event, text == "I will check that" {
          answerPublished.open()
        }
      }
    )

    // when
    let turn = Task { try await runtime.runTurn(request) }
    #expect(await probes.ready())
    // Stream progress must arrive before stepping the paced sender.
    #expect(await answerPublished.waitUntilOpen())
    #expect(await probes.advance(6))
    #expect(await toolStarted.waitUntilOpen())
    #expect(await probes.advance(140))
    let lastToolDraft = await drafts.markdowns.last
    let toolSnapshot = await snapshots.latest
    releaseTool.open()
    let result = await turn.result
    #expect(await probes.advance(6))
    await registry.close(runID: runID)

    // then
    let outcome = try result.get()
    let toolPhaseDraft = try #require(lastToolDraft)
    let toolLabel = try #require(toolSnapshot.steps.first?.label)
    #expect(toolPhaseDraft.contains(toolLabel))
    #expect(toolPhaseDraft.contains("Checking the forecast"))
    #expect(
      toolSnapshot.steps.first?.id
        == TurnToolStepID(providerCallID: "call-1", toolCallID: "same-call")
    )
    #expect(toolPhaseDraft.contains("I will check that") == false)
    guard case .completed(let content, let finalUsage, _) = outcome.result else {
      Issue.record("Expected completed answer")
      return
    }
    #expect(content == "final answer")
    #expect(content.contains("Checking the forecast") == false)
    try usage.recordUsage(finalUsage)
    let recordedProviderCallIDs = try await database.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT provider_call_id FROM provider_usage ORDER BY provider_call_id"
      )
    }
    #expect(recordedProviderCallIDs == ["call-1", "call-2"])
    #expect(await provider.requests.allSatisfy(\.progressExplanationsEnabled))
    #expect(await snapshots.latest.explanation == nil)
    #expect(await drafts.markdowns.contains { $0.contains("final answer") })
  }

  @Test
  func streamingResponseDoesNotWaitForBlockedDraftSend() async throws {
    // given — the presentation send remains held while the real provider runtime completes.
    let clock = ScriptedClock.compressed(parkingAt: .seconds(1))
    let drafts = ClosingDrafts()
    defer { drafts.releaseCleanup.open() }
    let registry = try makePresentations(clock: clock, drafts: drafts, typing: NoopTyping())
    let scope = progressScope()
    let reporter = try #require(await registry.begin(scope: scope))
    #expect(await drafts.started.waitUntilOpen())
    let provider = SequenceProvider([okResponse(content: "hello")])
    let runtime = try makeProgressRuntime(provider: provider, drafts: drafts)

    // when
    let outcome = try await runtime.runTurn(progressRequest(scope: scope, reporter: reporter))

    // then
    guard case .completed(let content, _, _) = outcome.result else {
      Issue.record("Expected completed answer")
      drafts.releaseCleanup.open()
      await registry.close(runID: scope.runID)
      return
    }
    #expect(content == "hello")
    #expect(await drafts.calls == 1)
    let close = Task { await registry.close(runID: scope.runID) }
    #expect(await drafts.cancelled.waitUntilOpen())
    drafts.releaseCleanup.open()
    await close.value
    await reporter.publish(.answerPreview("late"))
    #expect(await drafts.calls == 1)
  }

  @Test(arguments: [ExplanationDisabled.group, .streamingOff, .progressOff, .absentReporter])
  func explanationsRequireInteractivePrivateStreaming(_ scenario: ExplanationDisabled) async throws
  {
    // given
    let provider = SequenceProvider([okResponse()])
    let runtime = try makeProgressRuntime(
      provider: provider,
      drafts: NoopRichDraftStreaming(),
      streamingEnabled: scenario != .streamingOff
    )
    let reporter: TurnProgressReporter? =
      scenario == .absentReporter
      ? nil : TurnProgressReporter(explanationsEnabled: scenario != .progressOff) { _ in }
    let scope = progressScope(mode: scenario == .group ? .group : .direct)

    // when
    _ = try await runtime.runTurn(progressRequest(scope: scope, reporter: reporter))

    // then
    let request = try #require(await provider.requests.first)
    #expect(request.progressExplanationsEnabled == false)
  }

  enum ExplanationDisabled: Sendable {
    case group, streamingOff, progressOff, absentReporter
  }

}
