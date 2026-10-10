import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite
struct TurnProgressLifecycleTests {
  @Test
  func finalCommitWaitsForTheInFlightDraftToJoin() async throws {
    // given
    let drafts = ClosingDrafts()
    defer { drafts.releaseCleanup.open() }
    let provider = ProgressCompletionProvider()
    let registry = try makePresentations(
      clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
      drafts: drafts,
      typing: RecordingTyping()
    )
    let env = try makeEnv(
      agentOutcome: .respond(okResponse(content: "answer")),
      providerOverride: provider,
      presentations: registry
    )
    let turn = Task {
      try await env.runner.run(
        runID: env.runID,
        sessionID: env.sessionID,
        chatID: env.chatID,
        triggerMessageID: env.triggerMessageID
      )
    }
    let draftStarted = await drafts.started.waitUntilOpen()

    // when
    provider.complete.open()
    let closing = await drafts.cancelled.waitUntilOpen()
    let pendingBeforeJoin = try env.outbox.pendingOutbound()
    drafts.releaseCleanup.open()
    try await turn.value
    await registry.shutdown()

    // then
    #expect(draftStarted)
    #expect(closing)
    #expect(pendingBeforeJoin.isEmpty)
    #expect(drafts.cleaned.isOpen)
    #expect(try latestRunState(env.queue) == RunState.done.rawValue)
    #expect(try env.outbox.pendingOutbound().map(\.payload) == ["answer"])
  }
}

extension TurnProgressLifecycleTests {
  enum CancellationPhase: CaseIterable {
    case provider
    case approvedExecution
  }

  @Test(arguments: ["/stop", "/new", "draft stop"], CancellationPhase.allCases)
  func cancelAcknowledgementCannotBeFollowedByAnOldDraft(
    command: String,
    phase: CancellationPhase
  ) async throws {
    // given
    let drafts = ClosingDrafts(blockingText: phase == .provider ? nil : "Executing")
    defer { drafts.releaseCleanup.open() }
    let tool = ApprovedProgressTool()
    let suspended = AsyncGate()
    let stopped = AsyncGate()
    let providerStarted = AsyncGate()
    let providerRelease = AsyncGate()
    let harness = try makeSC3Harness(
      scripts: [
        phase == .provider
          ? [okResponse(content: "obsolete")]
          : [
            toolCallResponse([ToolCall(id: "write", name: "progress_write", argumentsJSON: "{}")]),
            okResponse(content: "obsolete"),
          ],
      ],
      httpResponses: [:],
      extraTools: [tool],
      notifyOutbox: { suspended.open() },
      beforeCompletion: { _, _ in
        providerStarted.open()
        if phase == .provider {
          await providerRelease.wait()
        }
        try Task.checkCancellation()
      },
      presentationsFactory: { outbox, draftIDs in
        try makePresentations(
          clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
          drafts: drafts,
          typing: RecordingTyping(),
          outbox: outbox,
          draftIDs: draftIDs
        )
      },
      transport: stoppedTransport(signal: stopped)
    )
    defer { harness.removeFiles() }
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "hello"))
    if phase == .approvedExecution {
      #expect(await suspended.waitUntilOpen())
      await OutboxDispatcher(
        outbox: harness.stores.outbox,
        delivery: harness.transport,
        signal: harness.outboxSignal,
        presentations: harness.presentations,
        logger: TestLog.silent
      ).drainOnce()
      let approval = try #require(try fetchApprovals(databasePath: harness.databasePath).first)
      _ = await harness.router.handle(
        rawUpdate: callbackUpdate(id: 3, from: 7, data: approveData(approval.nonce))
      )
      #expect(await tool.started.waitUntilOpen())
    }
    let started = await drafts.started.waitUntilOpen()
    let modelStarted = await providerStarted.waitUntilOpen()

    let draftID = try #require(await drafts.draftIDs.first)

    // when
    let commandTask = Task {
      let update: RawUpdate
      if command == "draft stop" {
        update = draftStopUpdate(id: 2, chat: 7, draftID: draftID)
      } else {
        update = textUpdate(id: 2, from: 7, text: command)
      }
      return await harness.router.handle(rawUpdate: update)
    }
    let closing = await drafts.cancelled.waitUntilOpen()
    let sendsBeforeJoin = await harness.transport.sent
    drafts.releaseCleanup.open()
    let outcome = await commandTask.value
    let joinedAtAcknowledgement = drafts.cleaned.isOpen
    let draftsAtAcknowledgement = await drafts.calls
    tool.release.open()
    providerRelease.open()
    if command == "draft stop" {
      #expect(await stopped.waitUntilOpen())
    }
    try await harness.stop()

    // then
    #expect(started && modelStarted && closing)
    #expect(
      sendsBeforeJoin.allSatisfy {
        $0.text != CommandReplies.stopped && $0.text != CommandReplies.freshConversation
      }
    )
    #expect(outcome == .processed)
    #expect(joinedAtAcknowledgement)
    #expect(await drafts.calls == draftsAtAcknowledgement)
    #expect(
      await harness.transport.sent.contains {
        $0.text == (command == "/new" ? CommandReplies.freshConversation : CommandReplies.stopped)
      }
    )
  }
}

extension TurnProgressLifecycleTests {
  @Test(arguments: [ToolObservationStatus.ok, .error])
  func progressLivesAcrossApprovalAndEndsBeforeFinalPublication(
    status: ToolObservationStatus
  ) async throws {
    // given
    let drafts = LifecycleDrafts()
    let provider = ApprovalProgressProvider(drafts: drafts)
    let tool = ApprovedProgressTool(status: status)
    let harness = try makeSC3Harness(
      scripts: [],
      httpResponses: [:],
      extraTools: [tool],
      providerOverride: provider,
      presentationsFactory: { outbox, draftIDs in
        try makePresentations(
          clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
          drafts: drafts,
          typing: RecordingTyping(),
          outbox: outbox,
          draftIDs: draftIDs
        )
      }
    )
    defer { harness.removeFiles() }
    let registry = try #require(harness.presentations)
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "save"))
    let waiting = await drafts.waitingSeen.waitUntilOpen()
    let approval = try #require(try fetchApprovals(databasePath: harness.databasePath).first)
    let dispatcher = OutboxDispatcher(
      outbox: harness.stores.outbox,
      delivery: harness.transport,
      signal: harness.outboxSignal,
      presentations: registry,
      logger: TestLog.silent
    )

    // when
    await dispatcher.drainOnce()
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 2, from: 7, data: approveData(approval.nonce))
    )
    let executed = await tool.started.waitUntilOpen()
    let executingVisible = await drafts.executingSeen.waitUntilOpen()
    tool.release.open()
    let resumed = await drafts.resumedSeen.waitUntilOpen()
    provider.releaseFinal.open()
    let laneFinished = AsyncGate()
    _ = await harness.lanes.enqueue(sessionID: try harness.sessionID(), runID: -1) {
      laneFinished.open()
    }
    let finished = await laneFinished.waitUntilOpen()
    try await harness.stop()

    // then
    #expect(waiting)
    #expect(executed)
    #expect(executingVisible)
    #expect(resumed)
    #expect(finished)
    let sent = await drafts.drafts
    #expect(sent.contains { $0.markdown.contains(status == .ok ? "Succeeded" : "Failed") })
    let initialDraft = try #require(sent.first)
    let resumedDraft = try #require(sent.first { $0.markdown.contains("resumed answer") })
    #expect(resumedDraft.draftID == initialDraft.draftID)
    #expect(
      try runState(databasePath: harness.databasePath, runID: approval.runID)
        == RunState.done.rawValue
    )
    let outboxPayloads = try harness.stores.outbox.pendingOutbound().map(\.payload)
    #expect(outboxPayloads.contains("final answer"))
    #expect(outboxPayloads.allSatisfy { !$0.contains("<tg-thinking>") })
    let explanation = ApprovalProgressProvider.explanation
    #expect(try harness.snapshot().history.allSatisfy { !$0.content.contains(explanation) })
    let ftsCount = try await harness.readPool.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH ?",
        arguments: [explanation]
      ) ?? 0
    }
    #expect(ftsCount == 0)
    #expect(try harness.auditRows().allSatisfy { !$0.argsRedacted.contains(explanation) })
  }
}

extension TurnProgressLifecycleTests {
  @Test
  func shutdownJoinsPresentationsBeforeClosingTelegram() async throws {
    // given
    let drafts = ClosingDrafts()
    defer { drafts.releaseCleanup.open() }
    let registry = try makePresentations(
      clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
      drafts: drafts,
      typing: RecordingTyping()
    )
    _ = await registry.begin(scope: progressScope())
    let started = await drafts.started.waitUntilOpen()
    let telegramClosed = AsyncGate()
    let coordinator = RuntimeShutdownCoordinator(
      logger: TestLog.silent,
      redactor: SecretRedactor(secretValues: [])
    )

    // when
    let shutdown = Task {
      await coordinator.shutDown(
        daemonError: nil,
        laneDrain: .drained,
        presentations: registry,
        dependent: .init(
          commitCredentials: {},
          closeLLMClient: {},
          closeTelegramClient: { telegramClosed.open() },
          closeToolClient: {}
        )
      )
    }
    let closing = await drafts.cancelled.waitUntilOpen()
    let closedBeforeJoin = telegramClosed.isOpen
    drafts.releaseCleanup.open()
    _ = await shutdown.value
    await registry.shutdown()

    // then
    #expect(started && closing)
    #expect(!closedBeforeJoin)
    #expect(telegramClosed.isOpen)
    #expect(drafts.cleaned.isOpen)
    #expect(await registry.begin(scope: progressScope()) == nil)
  }
}

extension TurnProgressLifecycleTests {
  enum TerminalBranch: CaseIterable {
    case contextFailure
    case providerFailure
  }

  @Test(arguments: TerminalBranch.allCases)
  func failureBranchesJoinBeforePublishing(branch: TerminalBranch) async throws {
    // given
    let drafts = ClosingDrafts()
    defer { drafts.releaseCleanup.open() }
    let registry = try makePresentations(
      clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
      drafts: drafts,
      typing: RecordingTyping()
    )
    let tinyContext = ContextBudget(
      inputCapGraphemes: 1,
      userFileCap: 1,
      memoryFileCap: 1,
      itemsCap: 1,
      historyCap: 1,
      recallCap: 1,
      skillsCap: 1,
      recallHitCap: 1
    )
    let env = try makeEnv(
      agentOutcome: .fail(.terminal(status: 400, message: "unavailable")),
      contextBudget: branch == .contextFailure ? tinyContext : .default,
      presentations: registry
    )
    _ = await registry.begin(
      scope: TurnScope(
        runID: env.runID,
        sessionID: env.sessionID,
        chatID: env.chatID,
        threadID: nil,
        mode: .direct,
        origin: .interactive,
        requesterUserID: env.chatID
      )
    )
    let started = await drafts.started.waitUntilOpen()

    // when
    let turn = Task {
      try await env.runner.run(
        runID: env.runID,
        sessionID: env.sessionID,
        chatID: env.chatID,
        triggerMessageID: env.triggerMessageID
      )
    }
    let closing = await drafts.cancelled.waitUntilOpen()
    let beforeJoin = try env.outbox.pendingOutbound()
    drafts.releaseCleanup.open()
    try await turn.value
    await registry.shutdown()

    // then
    #expect(started && closing)
    #expect(beforeJoin.isEmpty)
    #expect(drafts.cleaned.isOpen)
    #expect(try latestRunState(env.queue) == RunState.failed.rawValue)
    #expect(try env.outbox.pendingOutbound().isEmpty == false)
  }
}

extension TurnProgressLifecycleTests {
  @Test
  func deniedApprovalJoinsBeforeItsTerminalNotice() async throws {
    // given
    let drafts = ClosingDrafts()
    defer { drafts.releaseCleanup.open() }
    let suspended = AsyncGate()
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([
            ToolCall(id: "write", name: "progress_write", argumentsJSON: "{}"),
          ]),
        ],
      ],
      httpResponses: [:],
      extraTools: [ApprovedProgressTool()],
      notifyOutbox: { suspended.open() },
      presentationsFactory: { outbox, draftIDs in
        try makePresentations(
          clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
          drafts: drafts,
          typing: RecordingTyping(),
          outbox: outbox,
          draftIDs: draftIDs
        )
      }
    )
    defer { harness.removeFiles() }
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write"))
    #expect(await drafts.started.waitUntilOpen())
    #expect(await suspended.waitUntilOpen())
    let approval = try #require(try fetchApprovals(databasePath: harness.databasePath).first)

    // when — rejection and expiry share this terminal closure; expiry exercises its notice.
    #expect(try harness.stores.approvals.deny(id: approval.id, decision: .expired, now: Date()))
    await harness.coordinator.signal(.denied(.expired), forApprovalID: approval.id)
    let closing = await drafts.cancelled.waitUntilOpen()
    let beforeJoin = await harness.transport.sent
    drafts.releaseCleanup.open()
    let completed = AsyncGate()
    _ = await harness.lanes.enqueue(sessionID: try harness.sessionID(), runID: -1) {
      completed.open()
    }
    #expect(await completed.waitUntilOpen())
    try await harness.stop()

    // then
    #expect(closing)
    #expect(beforeJoin.isEmpty)
    #expect(drafts.cleaned.isOpen)
    #expect(
      try runState(databasePath: harness.databasePath, runID: approval.runID)
        == RunState.failed.rawValue
    )
    #expect(
      await harness.transport.sent.contains {
        $0.text == ApprovalWaiter.ownerNotice(for: .expired)
      }
    )
  }
}

extension TurnProgressLifecycleTests {
  @Test(arguments: ["/stop", "/new"])
  func cancelledLaneCannotRegisterADisplayAfterAcknowledgement(command: String) async throws {
    // given
    let pickedUp = AsyncGate()
    let admission = AsyncGate()
    let attempted = AsyncGate()
    let drafts = LifecycleDrafts()
    defer { admission.open() }
    let harness = try makeSC3Harness(
      scripts: [],
      httpResponses: [:],
      presentationsFactory: { outbox, draftIDs in
        try makePresentations(
          clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
          drafts: drafts,
          typing: RecordingTyping(),
          outbox: outbox,
          draftIDs: draftIDs
        )
      },
      turnsFactory: { runs, presentations in
        RegistrationTurn(
          runs: runs,
          presentations: presentations,
          pickedUp: pickedUp,
          admission: admission,
          attempted: attempted,
          draftSeen: drafts.firstSeen
        )
      }
    )
    defer { harness.removeFiles() }
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "hello"))
    let active = await pickedUp.waitUntilOpen()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 7, text: command)
    )
    let acknowledged = await harness.transport.sent.contains {
      $0.text == (command == "/stop" ? CommandReplies.stopped : CommandReplies.freshConversation)
    }
    admission.open()
    let attemptedAfterAck = await attempted.waitUntilOpen()
    try await harness.stop()

    // then
    #expect(active && acknowledged && attemptedAfterAck)
    #expect(outcome == .processed)
    #expect(await drafts.drafts.isEmpty)
    let expected = command == "/stop" ? RunState.cancelled : RunState.superseded
    #expect(try runStates(databasePath: harness.databasePath) == [expected.rawValue])
  }
}
