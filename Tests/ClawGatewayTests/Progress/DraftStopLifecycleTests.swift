import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite(.timeLimit(.minutes(1)))
struct DraftStopLifecycleTests {
  @Test
  func stopCancelsOnlyItsRunAndQueuedWorkRuns() async throws {
    // given
    let started = AsyncGate()
    let stopped = AsyncGate()
    let release = AsyncGate()
    defer {
      release.open()
    }
    let (harness, drafts) = try Self.makeHarness(
      scripts: [[okResponse(content: "queued answer")]],
      transport: stoppedTransport(signal: stopped),
      beforeCompletion: { count, _ in
        if count == 1 {
          started.open()
          await release.wait()
          try Task.checkCancellation()
        }
      }
    )
    defer {
      harness.removeFiles()
    }
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "first"))
    #expect(await started.waitUntilOpen())
    #expect(await drafts.firstSeen.waitUntilOpen())
    let draftID = try #require(await drafts.drafts.first?.draftID)
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "queued"))

    // when
    let stop = draftStopUpdate(id: 3, chat: 7, draftID: draftID)
    let result = await harness.router.handle(rawUpdate: stop)
    let duplicate = await harness.router.handle(rawUpdate: stop)
    let late = await harness.router.handle(
      rawUpdate: draftStopUpdate(id: 4, chat: 7, draftID: draftID)
    )
    #expect(await stopped.waitUntilOpen())
    let answers = try await harness.waitForOutbox(atLeast: 1)
    try await harness.stop()

    // then
    #expect(result == .processed)
    #expect(duplicate == .skipped && late == .skipped)
    #expect(
      try runStates(databasePath: harness.databasePath) == [
        RunState.cancelled.rawValue,
        RunState.done.rawValue,
      ]
    )
    #expect(answers == ["queued answer"])
    #expect(await harness.transport.sent.map(\.text) == [CommandReplies.stopped])
  }

  @Test
  func stopWhileAwaitingApprovalIsFinal() async throws {
    // given
    let tool = ApprovedProgressTool()
    let stopped = AsyncGate()
    let (harness, drafts) = try Self.makeHarness(
      scripts: Self.approvalScript,
      tools: [tool],
      transport: stoppedTransport(signal: stopped)
    )
    defer {
      harness.removeFiles()
    }
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write"))
    let approval = try #require(
      await pollUntil {
        try fetchApprovals(databasePath: harness.databasePath).first
      }
    )
    await OutboxDispatcher(
      outbox: harness.stores.outbox,
      delivery: harness.transport,
      signal: harness.outboxSignal,
      presentations: harness.presentations,
      logger: TestLog.silent
    ).drainOnce()
    #expect(await drafts.waitingSeen.waitUntilOpen())
    let draftID = try #require(await drafts.drafts.first?.draftID)

    // when
    let outcome = await harness.router.handle(
      rawUpdate: draftStopUpdate(id: 2, chat: 7, draftID: draftID)
    )
    #expect(await stopped.waitUntilOpen())
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 3, from: 7, data: approveData(approval.nonce))
    )
    try await harness.stop()

    // then
    #expect(outcome == .processed)
    #expect(try harness.stores.approvals.approval(id: approval.id)?.state == .rejected)
    #expect(
      try runState(databasePath: harness.databasePath, runID: approval.runID)
        == RunState.cancelled.rawValue
    )
    let observation = try await harness.readPool.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT content FROM messages
          WHERE id = (SELECT observation_message_id FROM approvals WHERE id = ?)
          """,
        arguments: [approval.id]
      )
    }
    #expect(observation == ApprovalWaiter.deniedObservationContent(for: .cancelled))
    #expect(!tool.started.isOpen)
    #expect(await harness.transport.sent.map(\.text) == [CommandReplies.stopped])
  }

  @Test
  func stopFromBeforeRestartChangesNothing() async throws {
    // given
    let tool = ApprovedProgressTool()
    let (first, oldDrafts) = try Self.makeHarness(scripts: Self.approvalScript, tools: [tool])
    defer {
      first.removeFiles()
    }
    _ = await first.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write"))
    let approval = try #require(
      await pollUntil {
        try fetchApprovals(databasePath: first.databasePath).first
      }
    )
    #expect(await oldDrafts.firstSeen.waitUntilOpen())
    let draftID = try #require(await oldDrafts.drafts.first?.draftID)
    try await first.stop()
    let second = try makeSC3Harness(
      scripts: [],
      httpResponses: [:],
      databasePath: first.databasePath,
      workspaceRoot: first.workspaceRoot,
      extraTools: [tool],
      presentationsFactory: { outbox, draftIDs in
        try makePresentations(
          clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
          drafts: LifecycleDrafts(),
          typing: RecordingTyping(),
          outbox: outbox,
          draftIDs: draftIDs
        )
      }
    )
    await second.runBootReconciliation()

    // when
    let result = await second.router.handle(
      rawUpdate: draftStopUpdate(id: 2, chat: 7, draftID: draftID)
    )
    try await second.stop()

    // then
    #expect(result == .skipped)
    #expect(
      try runState(databasePath: first.databasePath, runID: approval.runID)
        == RunState.awaitingApproval.rawValue
    )
    #expect(try second.stores.approvals.approval(id: approval.id)?.state == .pending)
    #expect(await second.transport.sent.isEmpty)
    #expect(!tool.started.isOpen)
  }

  @Test
  func oldStopCannotCancelRecoveredApprovedExecution() async throws {
    // given — crash after approval commits, before execution is claimed.
    let tool = ApprovedProgressTool()
    let (first, oldDrafts) = try Self.makeHarness(scripts: Self.approvalScript, tools: [tool])
    defer {
      first.removeFiles()
    }
    _ = await first.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write"))
    let approval = try #require(
      await pollUntil {
        try fetchApprovals(databasePath: first.databasePath).first
      }
    )
    await OutboxDispatcher(
      outbox: first.stores.outbox,
      delivery: first.transport,
      signal: first.outboxSignal,
      presentations: first.presentations,
      logger: TestLog.silent
    ).drainOnce()
    #expect(await oldDrafts.waitingSeen.waitUntilOpen())
    let oldDraftID = try #require(await oldDrafts.drafts.first?.draftID)
    try await first.stop()
    let stored = try #require(try first.stores.approvals.approval(id: approval.id))
    _ = try first.stores.approvals.approve(
      id: approval.id,
      currentPolicyVersion: stored.policyVersion,
      now: Date()
    )
    let newDrafts = LifecycleDrafts()
    let stopped = AsyncGate()
    let second = try makeSC3Harness(
      scripts: [],
      httpResponses: [:],
      databasePath: first.databasePath,
      workspaceRoot: first.workspaceRoot,
      extraTools: [tool],
      presentationsFactory: { outbox, draftIDs in
        try makePresentations(
          clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
          drafts: newDrafts,
          typing: RecordingTyping(),
          outbox: outbox,
          draftIDs: draftIDs
        )
      },
      transport: stoppedTransport(signal: stopped)
    )
    await second.runBootReconciliation()
    #expect(await tool.started.waitUntilOpen())
    #expect(await newDrafts.firstSeen.waitUntilOpen())
    let newDraftID = try #require(await newDrafts.drafts.first?.draftID)

    // when
    let oldResult = await second.router.handle(
      rawUpdate: draftStopUpdate(id: 2, chat: 7, draftID: oldDraftID)
    )
    let stateAfterOldStop = try runState(databasePath: first.databasePath, runID: approval.runID)
    let newResult = await second.router.handle(
      rawUpdate: draftStopUpdate(id: 3, chat: 7, draftID: newDraftID)
    )
    #expect(await stopped.waitUntilOpen())
    try await second.stop()

    // then
    #expect(newDraftID != oldDraftID)
    #expect(oldResult == .skipped)
    #expect(stateAfterOldStop == RunState.running.rawValue)
    #expect(newResult == .processed)
    #expect(
      try runState(databasePath: first.databasePath, runID: approval.runID)
        == RunState.cancelled.rawValue
    )
  }

  @Test
  func stopAfterCompletionSendsNothing() async throws {
    // given — retain a presentation while the durable completion has already won.
    let (harness, drafts) = try Self.makeHarness(scripts: [])
    defer {
      harness.removeFiles()
    }
    let claim = try harness.stores.sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: harness.sessionKey,
        chatID: 7,
        userID: 7,
        text: "hello",
        isEdited: false,
        journalAdmission: nil,
        ts: Date()
      )
    )
    let runID = try #require(claim.runID)
    let sessionID = try #require(claim.sessionID)
    _ = try harness.stores.runs.pickUp(runID: runID, now: Date())
    _ = await harness.presentations?.begin(
      scope: TurnScope(
        runID: runID,
        sessionID: sessionID,
        chatID: 7,
        threadID: nil,
        mode: .direct,
        origin: .interactive,
        requesterUserID: 7
      )
    )
    #expect(await drafts.firstSeen.waitUntilOpen())
    let draftID = try #require(await drafts.drafts.first?.draftID)
    try OutboxFixture.commitReply(
      in: harness.readPool,
      runID: runID,
      chunks: [
        OutboxChunk(stepIndex: 0, chatID: 7, payload: "answer", payloadHash: "answer"),
      ]
    )

    // when
    let result = await harness.router.handle(
      rawUpdate: draftStopUpdate(id: 2, chat: 7, draftID: draftID)
    )
    try await harness.stop()

    // then
    #expect(result == .processed)
    #expect(
      try runState(databasePath: harness.databasePath, runID: runID) == RunState.done.rawValue
    )
    #expect(try harness.stores.outbox.pendingOutbound().map(\.payload) == ["answer"])
    #expect(await harness.transport.sent.isEmpty)
  }

  @Test
  func stopDuringToolAcknowledgesAfterItsCleanup() async throws {
    // given
    let tool = DraftStopCleanupTool()
    defer {
      tool.releaseCleanup.open()
    }
    let stopped = AsyncGate()
    let transport = RecordingTransport(onSend: { text in
      if text == CommandReplies.stopped {
        #expect(tool.cleaned.isOpen)
        stopped.open()
      }
    })
    let (harness, drafts) = try Self.makeHarness(
      scripts: [
        [
          toolCallResponse([
            ToolCall(id: "cleanup", name: tool.definition.name, argumentsJSON: "{}"),
          ]),
          okResponse(content: "obsolete"),
        ],
      ],
      tools: [tool],
      transport: transport
    )
    defer {
      harness.removeFiles()
    }
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "work"))
    #expect(await tool.started.waitUntilOpen())
    #expect(await drafts.firstSeen.waitUntilOpen())
    let draftID = try #require(await drafts.drafts.first?.draftID)

    // when — returning while cleanup is held proves intake is free.
    let result = await harness.router.handle(
      rawUpdate: draftStopUpdate(id: 2, chat: 7, draftID: draftID)
    )
    #expect(result == .processed)
    #expect(await tool.cancelled.waitUntilOpen())
    let beforeCleanup = await transport.sent
    tool.releaseCleanup.open()
    #expect(await stopped.waitUntilOpen())
    try await harness.stop()

    // then
    #expect(beforeCleanup.isEmpty)
    #expect(
      try runStates(databasePath: harness.databasePath) == [RunState.cancelled.rawValue]
    )
    #expect(try harness.stores.outbox.pendingOutbound().isEmpty)
  }
}

// MARK: - Fixtures

private extension DraftStopLifecycleTests {
  static var approvalScript: [[ChatResponse]] {
    [
      [
        toolCallResponse([
          ToolCall(id: "write", name: "progress_write", argumentsJSON: "{}"),
        ]),
        okResponse(content: "obsolete"),
      ],
    ]
  }

  static func makeHarness(
    scripts: [[ChatResponse]],
    tools: [any Tool] = [],
    transport: RecordingTransport = RecordingTransport(),
    beforeCompletion: TurnScriptedProvider.BeforeCompletion? = nil
  ) throws -> (SC3Harness, LifecycleDrafts) {
    let drafts = LifecycleDrafts()
    let harness = try makeSC3Harness(
      scripts: scripts,
      httpResponses: [:],
      extraTools: tools,
      beforeCompletion: beforeCompletion,
      presentationsFactory: { outbox, draftIDs in
        try makePresentations(
          clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
          drafts: drafts,
          typing: RecordingTyping(),
          outbox: outbox,
          draftIDs: draftIDs
        )
      },
      transport: transport
    )
    return (harness, drafts)
  }
}

private struct DraftStopCleanupTool: Tool {
  let started = AsyncGate()
  let cancelled = AsyncGate()
  let releaseCleanup = AsyncGate()
  let cleaned = AsyncGate()
  let timeout: Duration = .seconds(60)

  var definition: ToolDefinition {
    ToolDefinition(
      name: "cleanup",
      description: "Cleanup probe",
      parameters: .object([:]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .safe
    )
  }

  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    nil
  }

  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    started.open()
    await AsyncGate().wait()
    cancelled.open()
    await releaseCleanup.waitIgnoringCancellation()
    cleaned.open()
    return ToolPayload(content: "cleaned", status: .error, ingestedUntrusted: false)
  }
}
