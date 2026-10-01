import ClawAgent
import ClawCore
import ClawData
import ClawTelegram
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite
struct TurnPresentationTests {
  @Test
  func longWorkRefreshesDraftAndRecoversTypingWhenDeliveryIsStale() async throws {
    // given
    let clock = ScriptedClock.compressed(parkingAt: .seconds(1))
    let recovered = AsyncGate()
    let drafts = ProgressDrafts(clock: clock, rejectAfter: .seconds(30))
    let typing = ProgressTyping(clock: clock, signalAfter: .seconds(55), signal: recovered)
    let registry = try makePresentations(clock: clock, drafts: drafts, typing: typing)
    let scope = progressScope()

    // when
    _ = await registry.begin(scope: scope)
    let observed = await recovered.waitUntilOpen()
    await registry.close(runID: scope.runID)

    // then
    try #require(observed)
    let sent = await drafts.sent
    let firstDraft = try #require(sent.first)
    let secondDraft = try #require(sent.dropFirst().first)
    #expect(firstDraft.draftID == scope.runID)
    #expect(secondDraft.time - firstDraft.time == .milliseconds(250))
    let successes = sent.filter(\.accepted)
    let successfulRefreshGaps = zip(successes, successes.dropFirst()).map {
      $1.time - $0.time
    }
    #expect(
      successfulRefreshGaps.allSatisfy {
        $0 <= .seconds(25)
      }
    )
    let lastSuccess = try #require(successes.last)
    #expect(lastSuccess.time >= .seconds(25))
    #expect(
      sent.allSatisfy {
        $0.draftID == scope.runID
      }
    )
    #expect(
      sent.contains {
        !$0.accepted
      }
    )
    let stalePhaseTypingTargets = await typing.targets
    #expect(stalePhaseTypingTargets.contains(.chat(scope.chatID)))
  }

  @Test
  func closingJoinsAnInFlightDraft() async throws {
    // given
    let clock = ScriptedClock.compressed(parkingAt: .seconds(1))
    let drafts = ClosingDrafts()
    defer {
      drafts.releaseCleanup.open()
    }
    let registry = try makePresentations(clock: clock, drafts: drafts, typing: RecordingTyping())
    let scope = progressScope()
    let reporter = await registry.begin(scope: scope)
    let started = await drafts.started.waitUntilOpen()

    // when
    let firstClose = Task {
      await registry.close(runID: scope.runID)
      return drafts.cleaned.isOpen
    }
    let cancelled = await drafts.cancelled.waitUntilOpen()
    let secondClose = Task {
      await registry.close(runID: scope.runID)
      return drafts.cleaned.isOpen
    }
    drafts.releaseCleanup.open()
    let firstJoined = await firstClose.value
    let secondJoined = await secondClose.value
    await reporter?.publish(.answerPreview("late"))
    await registry.shutdown()

    // then
    #expect(started && cancelled)
    #expect(firstJoined && secondJoined)
    #expect(await drafts.calls == 1)
  }

  @Test
  func topicTypingPausesForApprovalAndResumes() async throws {
    // given
    let probes = PresentationProbes()
    let clock = probes.clock
    let drafts = ProgressDrafts(clock: clock, rejectAfter: .seconds(100))
    let typing = RecordingTyping()
    let registry = try makePresentations(clock: clock, drafts: drafts, typing: typing)
    let scope = progressScope(mode: .group)
    let reporter = await registry.begin(scope: scope)
    #expect(await probes.ready())
    let step = TurnToolStepID(providerCallID: "round", toolCallID: "call")
    let tool = ToolDefinition(
      name: "file_write",
      description: "",
      parameters: .object([:]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .safe
    )
    await reporter?.publish(.toolStarted(id: step, tool: tool, preview: "file"))
    await reporter?.publish(.waitingForApproval(id: step))
    let beforeApproval = await typing.calls

    // when
    #expect(await probes.advance(20))
    let whileWaiting = await typing.calls
    await reporter?.publish(.toolState(id: step, state: .executing))
    #expect(await probes.advance(17))
    await registry.close(sessionID: scope.sessionID)

    // then
    #expect(whileWaiting == beforeApproval)
    let pulses = await typing.pulses
    #expect(pulses.count >= beforeApproval + 2)
    #expect(
      pulses.allSatisfy {
        $0.chatID == scope.chatID && $0.messageThreadID == scope.threadID
      }
    )
    #expect(await drafts.sent.isEmpty)
  }

  @Test
  func deliveryLeaseHoldsNewPresentationUntilPendingNoticeIsRecorded() async throws {
    // given
    let probes = PresentationProbes()
    let clock = probes.clock
    let drafts = ProgressDrafts(clock: clock, rejectAfter: .seconds(100))
    let typing = RecordingTyping()
    let writer = try TestDatabase.make()
    let outbox = OutboxStoreGRDB(writer: writer)
    let scope = progressScope()
    let registry = try makePresentations(
      clock: clock,
      drafts: drafts,
      typing: typing,
      outbox: outbox
    )
    let lease = await registry.beginDelivery(to: .chat(scope.chatID))
    let reporter = await registry.begin(scope: scope)
    #expect(await probes.ready())
    await reporter?.publish(.answerPreview("newest answer"))

    // when — a sent-but-unrecorded notice must continue holding drafts after the lease ends.
    try OutboxFixture.seedNotice(
      in: writer,
      chunk: LearningNoticeChunk(
        subjectDigest: "notice",
        ordinal: 0,
        chatID: scope.chatID,
        payload: "older notice",
        payloadHash: "hash"
      ),
      deliveryKey: "notice"
    )
    await registry.endDelivery(lease)
    #expect(await probes.advance(20))
    let heldDrafts = await drafts.sent
    let heldTyping = await typing.calls
    let retry = await registry.beginDelivery(to: .chat(scope.chatID))
    try outbox.markSent(deliveryKey: "notice", telegramMessageID: 1, now: Date())
    await registry.endDelivery(retry)
    #expect(await probes.advance(2))
    await registry.shutdown()

    // then
    #expect(heldDrafts.isEmpty)
    #expect(heldTyping >= 2)
    #expect(
      await drafts.sent.contains {
        $0.markdown.contains("newest answer")
      }
    )
  }

  @Test
  func registryRejectsCancelledProactiveAndShutdownAdmissions() async throws {
    // given
    let clock = ScriptedClock.compressed(parkingAt: .seconds(1))
    let drafts = ProgressDrafts(clock: clock, rejectAfter: .seconds(100))
    let registry = try makePresentations(clock: clock, drafts: drafts, typing: RecordingTyping())
    let admit = AsyncGate()
    let cancelled = Task {
      await admit.wait()
      return await registry.begin(scope: progressScope())
    }

    // when
    cancelled.cancel()
    let cancelledReporter = await cancelled.value
    let proactive = TurnScope(
      runID: 42,
      sessionID: 8,
      chatID: 99,
      threadID: nil,
      mode: .direct,
      origin: .scheduled,
      requesterUserID: nil
    )
    let proactiveReporter = await registry.begin(scope: proactive)
    await registry.shutdown()
    let stoppedReporter = await registry.begin(scope: progressScope())

    // then
    #expect(cancelledReporter == nil)
    #expect(proactiveReporter == nil)
    #expect(stoppedReporter == nil)
    #expect(await drafts.sent.isEmpty)
  }

  @Test
  func pausingDrainsDraftAndKeepsTypingAndLatestState() async throws {
    // given
    let probes = PresentationProbes()
    let clock = probes.clock
    let drafts = ClosingDrafts()
    defer {
      drafts.releaseCleanup.open()
    }
    let typing = RecordingTyping()
    let registry = try makePresentations(
      clock: clock,
      drafts: drafts,
      typing: typing,
      progressEnabled: false
    )
    let scope = progressScope()
    let reporter = await registry.begin(scope: scope)
    #expect(await probes.ready())
    await reporter?.publish(.answerPreview("same answer"))
    let advance = Task {
      await probes.advance(1)
    }
    let started = await drafts.started.waitUntilOpen()

    // when
    let pause = Task {
      let lease = await registry.beginDelivery(to: .chat(scope.chatID))
      return (lease, drafts.cleaned.isOpen)
    }
    let cancelled = await drafts.cancelled.waitUntilOpen()
    drafts.releaseCleanup.open()
    let (lease, joined) = await pause.value
    #expect(await advance.value)
    // Publication completes while the draft is excluded, and a paused owner keeps typing.
    await reporter?.publish(.answerPreview("newest answer"))
    #expect(await probes.advance(20))
    let whilePaused = await drafts.calls
    let typingWhilePaused = await typing.calls
    await registry.endDelivery(lease)
    #expect(await probes.advance(1))
    await registry.shutdown()

    // then
    #expect(started && cancelled && joined)
    #expect(whilePaused == 1)
    #expect(typingWhilePaused >= 2)
    #expect(await drafts.markdowns == ["same answer", "newest answer"])
  }

  @Test
  func disablingStreamingKeepsTypingWithoutDrafts() async throws {
    // given
    let probes = PresentationProbes()
    let clock = probes.clock
    let drafts = ProgressDrafts(clock: clock, rejectAfter: .seconds(100))
    let typing = RecordingTyping()
    let registry = try makePresentations(
      clock: clock,
      drafts: drafts,
      typing: typing,
      streamingEnabled: false
    )

    // when
    let reporter = await registry.begin(scope: progressScope())
    await reporter?.publish(.answerPreview("answer"))
    #expect(await probes.advance(20))
    await registry.shutdown()

    // then
    #expect(await drafts.sent.isEmpty)
    #expect(await typing.calls >= 2)
  }

  @Test
  func deliveryPauseResumesAnUnchangedFreshDraft() async throws {
    // given
    let probes = PresentationProbes()
    let clock = probes.clock
    let drafts = ProgressDrafts(clock: clock, rejectAfter: .seconds(100))
    let typing = RecordingTyping()
    let registry = try makePresentations(
      clock: clock,
      drafts: drafts,
      typing: typing,
      progressEnabled: false
    )
    let scope = progressScope()
    let reporter = await registry.begin(scope: scope)
    #expect(await probes.ready())
    await reporter?.publish(.answerPreview("same answer"))
    #expect(await probes.advance(2))
    let beforePause = await drafts.sent.count

    // when
    let lease = await registry.beginDelivery(to: .chat(scope.chatID))
    #expect(await probes.advance(16))
    let typingWhilePaused = await typing.calls
    await registry.endDelivery(lease)
    #expect(await probes.advance(1))
    await registry.shutdown()

    // then — delivery may clear a fresh bubble, so its same preview must be eligible again.
    #expect(beforePause == 2)
    #expect(typingWhilePaused >= 2)
    let sent = await drafts.sent
    #expect(sent.count == 3)
    #expect(
      sent.allSatisfy {
        $0.markdown == "same answer"
      }
    )
    let last = try #require(sent.last)
    #expect(last.time < .seconds(25))
  }

  @Test
  func pendingOutboxReadFailureKeepsDraftsPaused() async throws {
    // given
    let probes = PresentationProbes()
    let clock = probes.clock
    let drafts = ProgressDrafts(clock: clock, rejectAfter: .seconds(100))
    let typing = RecordingTyping()
    let writer = try TestDatabase.make()
    try await writer.write { db in
      try db.execute(sql: "DROP TABLE outbound_deliveries")
    }
    let registry = try makePresentations(
      clock: clock,
      drafts: drafts,
      typing: typing,
      outbox: OutboxStoreGRDB(writer: writer)
    )

    // when
    _ = await registry.begin(scope: progressScope())
    #expect(await probes.advance(20))
    await registry.shutdown()

    // then
    #expect(await drafts.sent.isEmpty)
    #expect(await typing.calls >= 2)
  }

}
