import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

private func voiceUpdate(id: Int64, from: Int64, durationSeconds: Int = 8) -> RawUpdate {
  RawUpdate(
    updateId: id,
    message: RawMessage(
      messageId: id,
      fromUserId: from,
      chatId: from,
      text: nil,
      caption: nil,
      mediaKind: VoiceAttachment.mediaKindDescription,
      voice: VoiceAttachment(
        fileId: "voice-\(id)",
        durationSeconds: durationSeconds,
        mimeType: "audio/ogg",
        fileSizeBytes: 4
      )
    ),
    editedMessage: nil
  )
}

@Suite struct VoiceRoutingTests {
  private struct Harness {
    let router: MessageRouter
    let transport: RecordingTransport
    let dispatcher: FakeTurnRunner
    let sessionMessages: SessionMessageStoreGRDB
    let pendingConfirmations: PendingConfirmationRegistry
    let fetcher: StubMediaFetcher
    let staging: URL
  }

  private func makeHarness(
    allowed: [Int64],
    voiceEnabled: Bool = true,
    fetcher: StubMediaFetcher = StubMediaFetcher(),
    transcriber: any VoiceTranscribing = StubVoiceTranscriber(),
    serviceOverride: (any VoiceMessageTranscribing)? = nil
  ) throws -> Harness {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: allowed)

    let transport = RecordingTransport()
    let dispatcher = FakeTurnRunner()
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let pendingConfirmations = PendingConfirmationRegistry()
    let staging = try makeTemporaryRoot(prefix: "voice-routing-tests")

    let voice: (any VoiceMessageTranscribing)? =
      serviceOverride
      ?? (voiceEnabled
        ? VoiceMessageService(
          fetcher: fetcher,
          transcriber: transcriber,
          stagingDirectory: staging,
          redactor: SecretRedactor(secretValues: []),
          logger: TestLog.silent
        )
        : nil)

    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: sessionMessages,
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: pendingConfirmations,
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist),
      delivery: transport,
      turnRunner: dispatcher,
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      voice: voice,
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      logger: TestLog.silent
    )

    return Harness(
      router: router,
      transport: transport,
      dispatcher: dispatcher,
      sessionMessages: sessionMessages,
      pendingConfirmations: pendingConfirmations,
      fetcher: fetcher,
      staging: staging
    )
  }

  @Test func ownerVoiceDispatchesAnUntrustedTurnAndTaintsTheSession() async throws {
    // given
    let harness = try makeHarness(allowed: [42])
    defer { try? FileManager.default.removeItem(at: harness.staging) }

    // when
    let outcome = await harness.router.handle(rawUpdate: voiceUpdate(id: 1, from: 42))
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then — the transcript became the turn's text, persisted untrusted, and the session tainted
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.isEmpty)
    let call = try #require(await harness.dispatcher.calls.first)
    let snapshot = try harness.sessionMessages.loadContextSnapshot(
      sessionId: call.sessionId,
      throughMessageId: call.triggerMessageId,
      limit: 10
    )
    #expect(
      snapshot.history == [
        StoredMessage(role: .user, content: "spoken words", provenance: .untrusted)
      ]
    )
    #expect(snapshot.isTainted)
  }

  @Test func spokenCommandIsNeverParsedAsACommand() async throws {
    // given — a transcript that reads exactly like /stop
    let harness = try makeHarness(
      allowed: [42],
      transcriber: StubVoiceTranscriber(result: .success("/stop"))
    )
    defer { try? FileManager.default.removeItem(at: harness.staging) }

    // when
    let outcome = await harness.router.handle(rawUpdate: voiceUpdate(id: 1, from: 42))
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then — it dispatched an ordinary turn; no command reply was sent
    #expect(outcome == .processed)
    #expect(await harness.dispatcher.calls.count == 1)
    #expect(await harness.transport.sent.isEmpty)
  }

  @Test func voiceTranscriptNeverResolvesAParkedConfirmation() async throws {
    // given — a parked yes/no confirmation, and a voice note whose transcript is exactly "yes"
    let harness = try makeHarness(
      allowed: [42],
      transcriber: StubVoiceTranscriber(result: .success("yes"))
    )
    defer { try? FileManager.default.removeItem(at: harness.staging) }
    let sessionId = try harness.sessionMessages.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 42),
      now: Date()
    )
    await harness.pendingConfirmations.park(
      .command(.deleteItem(id: 7)),
      sessionId: sessionId
    )

    // when
    let outcome = await harness.router.handle(rawUpdate: voiceUpdate(id: 1, from: 42))
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then — machine-derived "yes" commits nothing: the confirmation stays parked and the
    // transcript became an ordinary untrusted turn
    #expect(outcome == .processed)
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) != nil)
    #expect(await harness.dispatcher.calls.count == 1)
    #expect(await harness.transport.sent.isEmpty)
  }

  @Test func storageFullDuringVoiceHandlingReturnsTheBackoffOutcome() async throws {
    // given — a service hitting a full disk while staging
    let harness = try makeHarness(
      allowed: [42],
      serviceOverride: ScriptedVoiceService(result: .failure(.storageFull))
    )
    defer { try? FileManager.default.removeItem(at: harness.staging) }

    // when
    let outcome = await harness.router.handle(rawUpdate: voiceUpdate(id: 1, from: 42))

    // then — the poller contract: storage-full notice, backoff outcome (cursor must NOT
    // advance), no turn
    #expect(outcome == .storageFull)
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [Degradation.storageFull])
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func voiceWithoutAServiceGetsTheCannedUnsupportedReply() async throws {
    // given — transcription off: exactly the pre-feature behavior
    let harness = try makeHarness(allowed: [42], voiceEnabled: false)
    defer { try? FileManager.default.removeItem(at: harness.staging) }

    // when
    let outcome = await harness.router.handle(rawUpdate: voiceUpdate(id: 1, from: 42))

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(
      sent.map(\.text) == [
        MessageRouter.unsupportedMediaText(kind: VoiceAttachment.mediaKindDescription)
      ]
    )
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func strangerVoiceGetsPrivateBotReplyAndNeverDownloads() async throws {
    // given
    let harness = try makeHarness(allowed: [42])
    defer { try? FileManager.default.removeItem(at: harness.staging) }

    // when — a non-allowlisted sender's voice note
    await harness.router.handle(rawUpdate: voiceUpdate(id: 1, from: 7))

    // then — fail-closed: the private-bot line, no fetch, no turn
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [MessageRouter.privateBotText])
    #expect(await harness.fetcher.calls.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func strangerVoiceWithTranscriptionDisabledStillGetsPrivateBotReply() async throws {
    // given — the access check must outrank the service-availability check
    let harness = try makeHarness(allowed: [42], voiceEnabled: false)
    defer { try? FileManager.default.removeItem(at: harness.staging) }

    // when
    await harness.router.handle(rawUpdate: voiceUpdate(id: 1, from: 7))

    // then — the stranger learns nothing about voice capabilities either way
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [MessageRouter.privateBotText])
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func transcriberFailureGetsItsMappedReplyAndNoTurn() async throws {
    // given
    let harness = try makeHarness(
      allowed: [42],
      transcriber: StubVoiceTranscriber(result: .failure(.undecodableAudio("bad header")))
    )
    defer { try? FileManager.default.removeItem(at: harness.staging) }

    // when
    let outcome = await harness.router.handle(rawUpdate: voiceUpdate(id: 1, from: 42))

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [VoiceMessageService.Failure.undecodableAudio.ownerReplyText])
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func overlongVoiceIsRefusedBeforeAnyDownload() async throws {
    // given
    let harness = try makeHarness(allowed: [42])
    defer { try? FileManager.default.removeItem(at: harness.staging) }

    // when — an hour-long recording
    await harness.router.handle(rawUpdate: voiceUpdate(id: 1, from: 42, durationSeconds: 3_600))

    // then — refused on declared duration; not a single byte fetched
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [VoiceMessageService.Failure.tooLong.ownerReplyText])
    #expect(await harness.fetcher.calls.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func shutdownCancellationLeavesTheVoiceUpdateUnclaimedForRedelivery() async throws {
    // given — an engine parked mid-transcription when graceful shutdown cancels the intake task
    let harness = try makeHarness(allowed: [42], transcriber: ParkUntilCancelledTranscriber())
    defer { try? FileManager.default.removeItem(at: harness.staging) }
    let update = voiceUpdate(id: 1, from: 42)

    // when — the poller task is cancelled while the voice note is still being handled
    let intake = Task {
      await harness.router.handle(rawUpdate: update)
    }
    intake.cancel()
    let outcome = await intake.value

    // then — a no-claim retry: nothing sent, no turn, the update left for the re-poll …
    #expect(outcome == .transientFailure)
    #expect(await harness.transport.sent.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)

    // … so the post-restart redelivery produces the turn the first delivery never did
    let redelivered = await harness.router.handle(rawUpdate: update)
    #expect(redelivered == .processed)
  }

  @Test func downloadFailureGetsItsMappedReply() async throws {
    // given
    let harness = try makeHarness(allowed: [42], fetcher: StubMediaFetcher(audio: nil))

    // when
    await harness.router.handle(rawUpdate: voiceUpdate(id: 1, from: 42))

    // then
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [VoiceMessageService.Failure.downloadFailed.ownerReplyText])
    #expect(await harness.dispatcher.calls.isEmpty)
  }
}
