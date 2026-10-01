import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite
struct TurnProgressDeliveryTests {
  enum DeliveryBranch: CaseIterable {
    case ordinary
    case boot
    case markSentFailure
  }

  @Test(arguments: DeliveryBranch.allCases)
  func olderPendingAnswerHoldsOnlyTheNewDraft(branch: DeliveryBranch) async throws {
    // given
    let fixture = try makeSeededFixture()
    try OutboxFixture.commitReply(
      in: fixture.writer,
      runID: fixture.runID,
      chunks: [
        OutboxChunk(
          stepIndex: 0,
          chatID: fixture.chatID,
          payload: "older answer",
          payloadHash: ContentHash.fnv1a("older answer")
        ),
      ]
    )
    let nextRunID = try seedRun(in: fixture.writer, chatID: fixture.chatID, updateID: 2)
    let context = try #require(
      try fixture.runs.executionContext(runID: nextRunID, fallbackChatID: fixture.chatID)
    )
    let probes = PresentationProbes()
    let clock = probes.clock
    let drafts = ProgressDrafts(clock: clock, rejectAfter: .seconds(100))
    let registry = try makePresentations(
      clock: clock,
      drafts: drafts,
      typing: RecordingTyping(),
      outbox: fixture.outbox
    )
    let transport = RecordingTransport()
    let signal = OutboxSignal()
    let dispatcher = OutboxDispatcher(
      outbox: branch == .markSentFailure
        ? MarkSentFailingOutbox(base: fixture.outbox) : fixture.outbox,
      delivery: transport,
      signal: signal,
      presentations: registry,
      logger: TestLog.silent
    )
    let scope = TurnScope(
      runID: nextRunID,
      sessionID: context.sessionID,
      chatID: fixture.chatID,
      threadID: nil,
      mode: .direct,
      origin: .interactive,
      requesterUserID: fixture.chatID
    )
    let reporter = await registry.begin(scope: scope)
    let provider = ProgressCompletionProvider()
    let runtime = try makeProgressRuntime(
      provider: provider,
      drafts: drafts,
      streamingEnabled: false
    )
    let inference = Task {
      try await runtime.runTurn(progressRequest(scope: scope, reporter: reporter))
    }
    #expect(await provider.started.waitUntilOpen())
    #expect(await probes.advance(2))
    #expect(await drafts.sent.isEmpty)

    // when
    if branch == .boot {
      signal.finish()
      try await dispatcher.run()
    } else {
      await dispatcher.drainOnce()
    }
    #expect(await probes.advance(6))
    provider.complete.open()
    _ = try await inference.value
    await registry.shutdown()

    // then
    #expect(try fixture.outbox.pendingOutbound().isEmpty == (branch != .markSentFailure))
    #expect(await transport.richSends.contains { $0.markdown == "older answer" })
    if branch == .markSentFailure {
      #expect(await drafts.sent.isEmpty)
    } else {
      #expect(await drafts.sent.contains { $0.draftID == nextRunID })
    }
  }
}

extension TurnProgressDeliveryTests {
  @Test
  func commandAcknowledgementDrainsTheActiveDraftBeforeSending() async throws {
    // given
    let fixture = try makeSeededFixture()
    let drafts = ClosingDrafts()
    defer { drafts.releaseCleanup.open() }
    let registry = try makePresentations(
      clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
      drafts: drafts,
      typing: RecordingTyping(),
      outbox: fixture.outbox
    )
    let scope = progressScope()
    _ = await registry.begin(scope: scope)
    let started = await drafts.started.waitUntilOpen()
    let transport = RecordingTransport()
    let sender = ReplySender(
      processed: ProcessedUpdateStoreGRDB(writer: fixture.writer),
      delivery: transport,
      logger: TestLog.silent,
      presentations: registry
    )

    // when
    let ack = Task {
      await sender.sendCommandAck(updateID: 2, target: .chat(scope.chatID), text: "ack")
    }
    let cancelled = await drafts.cancelled.waitUntilOpen()
    let premature = await transport.sent
    drafts.releaseCleanup.open()
    let result = await ack.value
    await registry.shutdown()

    // then
    #expect(started && cancelled)
    #expect(premature.isEmpty)
    #expect(result == .processed)
    #expect(await transport.sent.contains { $0.text == "ack" })
  }
}

extension TurnProgressDeliveryTests {
  @Test
  func approvalCardDrainsTheDraftThenReleasesTheWaitingDisplay() async throws {
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
      presentationsFactory: { outbox in
        try makePresentations(
          clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
          drafts: drafts,
          typing: RecordingTyping(),
          outbox: outbox
        )
      }
    )
    defer { harness.removeFiles() }
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write"))
    let started = await drafts.started.waitUntilOpen()
    let parked = await suspended.waitUntilOpen()
    let dispatcher = OutboxDispatcher(
      outbox: harness.stores.outbox,
      delivery: harness.transport,
      signal: harness.outboxSignal,
      presentations: harness.presentations,
      logger: TestLog.silent
    )

    // when
    let delivery = Task { await dispatcher.drainOnce() }
    let draining = await drafts.cancelled.waitUntilOpen()
    let premature = await harness.transport.richSends
    drafts.releaseCleanup.open()
    await delivery.value
    let waitingResumed = await drafts.waitingAfterCleanup.waitUntilOpen()
    let pendingAfterDelivery = try harness.stores.outbox.pendingOutbound()
    try await harness.stop()

    // then
    #expect(started && parked && draining)
    #expect(premature.isEmpty)
    #expect(waitingResumed)
    #expect(pendingAfterDelivery.isEmpty)
    #expect(await harness.transport.richSends.isEmpty == false)
  }
}

extension TurnProgressDeliveryTests {
  @Test
  func callbackFactoryDrainsWaitingDraftBeforeStorageFullNotice() async throws {
    // given
    let fixture = try makeSeededFixture()
    try await fixture.writer.write { db in
      db.add(
        function: DatabaseFunction("fail_callback_claim", argumentCount: 0) { _ in
          throw DatabaseError(resultCode: .SQLITE_FULL)
        }
      )
      try db.execute(
        sql: """
          CREATE TRIGGER callback_claim_full BEFORE INSERT ON processed_updates
          WHEN NEW.update_id = 99 BEGIN SELECT fail_callback_claim(); END
          """
      )
    }
    let drafts = ClosingDrafts(blockingText: "Waiting for your approval")
    defer { drafts.releaseCleanup.open() }
    let registry = try makePresentations(
      clock: ScriptedClock.compressed(parkingAt: .seconds(1)),
      drafts: drafts,
      typing: RecordingTyping(),
      outbox: fixture.outbox
    )
    let scope = progressScope()
    let reporter = await registry.begin(scope: scope)
    let stepID = TurnToolStepID(providerCallID: "approval-round", toolCallID: "write")
    await reporter?.publish(
      .toolStarted(
        id: stepID,
        tool: ApprovedProgressTool().definition,
        preview: nil
      )
    )
    await reporter?.publish(.waitingForApproval(id: stepID))
    let started = await drafts.started.waitUntilOpen()
    let transport = RecordingTransport()
    let handler = ApprovalCallbackHandler.make(
      processed: ProcessedUpdateStoreGRDB(writer: fixture.writer),
      delivery: transport,
      accessControl: AccessControl(
        allowlist: AllowlistStoreGRDB(writer: fixture.writer),
        groupChats: []
      ),
      approvals: ApprovalStoreGRDB(writer: fixture.writer),
      runs: fixture.runs,
      membership: transport,
      audit: AuditLogGRDB(writer: fixture.writer),
      coordinator: ApprovalCoordinator(),
      callbacks: transport,
      currentPolicyVersion: { "pv" },
      now: { Date() },
      presentations: registry,
      logger: TestLog.silent
    )
    let callback = try #require(
      callbackUpdate(id: 99, from: scope.chatID, data: approveData("pending")).callback
    )

    // when
    let handling = Task { await handler.handle(callback, updateID: 99) }
    let draining = await drafts.cancelled.waitUntilOpen()
    let premature = await transport.sent
    drafts.releaseCleanup.open()
    let outcome = await handling.value
    await registry.shutdown()

    // then
    #expect(started && draining)
    #expect(premature.isEmpty)
    #expect(outcome == .storageFull)
    #expect(await transport.sent.contains { $0.text == Degradation.storageFull })
  }
}
