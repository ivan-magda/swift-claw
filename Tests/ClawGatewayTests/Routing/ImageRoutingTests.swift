import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

private func photoUpdate(id: Int64, from: Int64, caption: String? = nil) -> RawUpdate {
  RawUpdate(
    updateId: id,
    message: RawMessage(
      messageId: id,
      fromUserId: from,
      chatId: from,
      text: nil,
      caption: caption,
      mediaKind: PhotoAttachment.mediaKindDescription,
      photo: PhotoAttachment(sizes: [
        PhotoSize(
          fileId: "photo-\(id)",
          fileUniqueId: "u-\(id)",
          width: 1280,
          height: 960,
          fileSizeBytes: 186_422
        )
      ])
    ),
    editedMessage: nil
  )
}

@Suite struct ImageRoutingTests {
  private struct Harness {
    let router: MessageRouter
    let transport: RecordingTransport
    let dispatcher: FakeTurnRunner
    let sessionMessages: SessionMessageStoreGRDB
    let pendingConfirmations: PendingConfirmationRegistry
    let cache: ImageCache
  }

  private let fetched = ImagePart(
    data: ImageFixtures.jpeg,
    mediaType: .jpeg,
    width: 1280,
    height: 960
  )

  private func makeHarness(
    allowed: [Int64],
    imagesEnabled: Bool = true,
    fetcher: any MediaFetching = StubMediaFetcher(result: .success(ImageFixtures.jpeg)),
    typing: any TypingIndicator = NoopTyping()
  ) throws -> Harness {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: allowed)

    let transport = RecordingTransport()
    let dispatcher = FakeTurnRunner()
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let pendingConfirmations = PendingConfirmationRegistry()
    let cache = ImageCache()

    let service = ImageMessageService(media: fetcher, logger: TestLog.silent)
    let images: (any ImageMessageHandling)? = imagesEnabled ? service : nil

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
      images: images,
      typing: typing,
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      logger: TestLog.silent
    )

    return Harness(
      router: router.withImageCache(cache),
      transport: transport,
      dispatcher: dispatcher,
      sessionMessages: sessionMessages,
      pendingConfirmations: pendingConfirmations,
      cache: cache
    )
  }

  @Test func ownerPhotoDispatchesAnUntrustedTurnAndCachesTheBytes() async throws {
    // given
    let harness = try makeHarness(allowed: [42])

    // when
    let outcome = await harness.router.handle(
      rawUpdate: photoUpdate(id: 1, from: 42, caption: "Что это?")
    )
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then — the caption became the turn's text behind the marker, persisted untrusted, the session
    // tainted …
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.isEmpty)
    let call = try #require(await harness.dispatcher.calls.first)
    let snapshot = try harness.sessionMessages.loadContextSnapshot(
      sessionId: call.sessionId,
      throughMessageId: call.triggerMessageId,
      limit: 10
    )
    // The marker leads even when captioned — the row's only surviving evidence that it carried a
    // photo, since the bytes are never persisted. Spelled out rather than built by `photoContent`,
    // so a change to that shape fails here instead of agreeing with itself.
    #expect(
      snapshot.history == [
        StoredMessage(
          role: .user,
          content: "\(ImageMarkers.barePhoto) Что это?",
          provenance: .untrusted
        )
      ]
    )
    #expect(snapshot.isTainted)

    // … and the bytes are waiting on the row the turn was triggered by
    let cached = await harness.cache.images(sessionId: call.sessionId)
    #expect(cached == [call.triggerMessageId: fetched])
  }

  @Test func aBarePhotoPersistsThePlaceholderRatherThanAnEmptyRow() async throws {
    // given — no caption at all
    let harness = try makeHarness(allowed: [42])

    // when
    let outcome = await harness.router.handle(rawUpdate: photoUpdate(id: 1, from: 42))
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then
    #expect(outcome == .processed)
    let call = try #require(await harness.dispatcher.calls.first)
    let snapshot = try harness.sessionMessages.loadContextSnapshot(
      sessionId: call.sessionId,
      throughMessageId: call.triggerMessageId,
      limit: 10
    )
    #expect(snapshot.history.map(\.content) == [ImageMarkers.barePhoto])
  }

  @Test func aCaptionIsNeverParsedAsACommand() async throws {
    // given — a caption that reads exactly like /stop
    let harness = try makeHarness(allowed: [42])

    // when
    let outcome = await harness.router.handle(
      rawUpdate: photoUpdate(id: 1, from: 42, caption: "/stop")
    )

    // then — no command ran, and the caption became an ordinary turn
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.isEmpty)
    await harness.dispatcher.waitForCalls(atLeast: 1)
    #expect(await harness.dispatcher.calls.count == 1)
  }

  @Test func aCaptionNeverResolvesAParkedConfirmation() async throws {
    // given — a parked yes/no confirmation, and a photo captioned exactly "yes"
    let harness = try makeHarness(allowed: [42])
    let sessionId = try harness.sessionMessages.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 42),
      now: Date()
    )
    await harness.pendingConfirmations.park(.deleteItem(id: 7), sessionId: sessionId)

    // when
    let outcome = await harness.router.handle(
      rawUpdate: photoUpdate(id: 1, from: 42, caption: "yes")
    )

    // then — a caption commits nothing: the confirmation stays parked and the photo became an
    // ordinary turn
    #expect(outcome == .processed)
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) != nil)
    #expect(await harness.transport.sent.isEmpty)
    await harness.dispatcher.waitForCalls(atLeast: 1)
    #expect(await harness.dispatcher.calls.count == 1)
  }

  @Test func theOwnerSeesTypingWhileThePhotoDownloads() async throws {
    // given
    let typing = RecordingTyping()
    let harness = try makeHarness(allowed: [42], typing: typing)

    // when
    let outcome = await harness.router.handle(rawUpdate: photoUpdate(id: 1, from: 42))

    // then — the download is the only thing between the photo and the turn, so it is what the
    // pulse covers
    #expect(outcome == .processed)
    #expect(await typing.calls == 1)
  }

  @Test func aStrangerNeverSeesTyping() async throws {
    // given — a pulse would confirm the bot is live to someone who must learn nothing
    let typing = RecordingTyping()
    let harness = try makeHarness(allowed: [42], typing: typing)

    // when
    await harness.router.handle(rawUpdate: photoUpdate(id: 1, from: 7))

    // then
    #expect(await typing.calls == 0)
  }

  @Test func aDisabledImageServiceNeverPulsesTyping() async throws {
    // given — the canned "can't read photos yet" reply is instant, not work in progress
    let typing = RecordingTyping()
    let harness = try makeHarness(allowed: [42], imagesEnabled: false, typing: typing)

    // when
    await harness.router.handle(rawUpdate: photoUpdate(id: 1, from: 42))

    // then
    #expect(await typing.calls == 0)
  }

  @Test func strangerPhotoGetsPrivateBotReplyAndNeverDownloads() async throws {
    // given
    let fetcher = StubMediaFetcher(result: .success(ImageFixtures.jpeg))
    let harness = try makeHarness(allowed: [42], fetcher: fetcher)

    // when — a non-allowlisted sender's photo
    await harness.router.handle(rawUpdate: photoUpdate(id: 1, from: 7))

    // then — fail-closed: the private-bot line, no fetch, no turn
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [MessageRouter.privateBotText])
    #expect(await fetcher.calls.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func strangerPhotoWithImagesDisabledStillGetsPrivateBotReply() async throws {
    // given — the access check must outrank the service-availability check
    let harness = try makeHarness(allowed: [42], imagesEnabled: false)

    // when
    await harness.router.handle(rawUpdate: photoUpdate(id: 1, from: 7))

    // then — the stranger learns nothing about image capabilities either way
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [MessageRouter.privateBotText])
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func aBarePhotoWithoutAServiceGetsTheCannedUnsupportedReply() async throws {
    // given — no image service, and nothing but the photo: the bare arm of the opted-out fork
    let harness = try makeHarness(allowed: [42], imagesEnabled: false)

    // when
    let outcome = await harness.router.handle(rawUpdate: photoUpdate(id: 1, from: 42))

    // then — exactly the pre-feature behavior: the canned line, no turn
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(
      sent.map(\.text) == [
        MessageRouter.unsupportedMediaText(kind: PhotoAttachment.mediaKindDescription)
      ]
    )
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func aCaptionedPhotoWithoutAServiceStillAnswersTheOwnersQuestion() async throws {
    // given — the configuration the product itself recommends to an owner on a text-only model.
    // Their caption is a real question and must not be swallowed by the canned reply.
    let harness = try makeHarness(allowed: [42], imagesEnabled: false)

    // when
    let outcome = await harness.router.handle(
      rawUpdate: photoUpdate(id: 1, from: 42, caption: "what does this say")
    )

    // then — no canned reply stood in for the answer. Required before the dispatch wait, which is
    // unbounded by design: a regression that swallows the caption must fail here rather than hang
    // waiting for a turn that will never come.
    try #require(await harness.transport.sent.isEmpty)
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // … and the turn carries the marker and the caption, persisted untrusted
    #expect(outcome == .processed)
    let call = try #require(await harness.dispatcher.calls.first)
    let snapshot = try harness.sessionMessages.loadContextSnapshot(
      sessionId: call.sessionId,
      throughMessageId: call.triggerMessageId,
      limit: 10
    )
    #expect(
      snapshot.history == [
        StoredMessage(
          role: .user,
          content: "\(ImageMarkers.barePhoto) what does this say",
          provenance: .untrusted
        )
      ]
    )
    #expect(snapshot.isTainted)

    // … and no bytes were cached, so assembly renders the unavailable notice rather than letting the
    // model answer about pixels that were never downloaded
    #expect(await harness.cache.images(sessionId: call.sessionId).isEmpty)
  }

  @Test func aCaptionWithoutAServiceIsStillNeverParsedAsACommand() async throws {
    // given — the opted-out path reaches dispatch, so it must clear the same bar as the enabled
    // one: a caption is untrusted content, never owner intent
    let harness = try makeHarness(allowed: [42], imagesEnabled: false)
    let sessionId = try harness.sessionMessages.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 42),
      now: Date()
    )
    await harness.pendingConfirmations.park(.deleteItem(id: 7), sessionId: sessionId)

    // when — a caption that reads exactly like a confirmation
    let outcome = await harness.router.handle(
      rawUpdate: photoUpdate(id: 1, from: 42, caption: "yes")
    )

    // then — nothing was committed and the confirmation stays parked
    #expect(outcome == .processed)
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) != nil)
    try #require(await harness.transport.sent.isEmpty)
    await harness.dispatcher.waitForCalls(atLeast: 1)
    #expect(await harness.dispatcher.calls.count == 1)
  }

  @Test func downloadFailureGetsItsMappedReplyAndNoTurn() async throws {
    // given
    let harness = try makeHarness(allowed: [42], fetcher: StubMediaFetcher.failing)

    // when
    let outcome = await harness.router.handle(rawUpdate: photoUpdate(id: 1, from: 42))

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [ImageMessageFailure.fetchFailed.ownerReplyText])
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func undecodableBytesGetTheirMappedReplyAndNoTurn() async throws {
    // given — a body that is not an image at all
    let harness = try makeHarness(
      allowed: [42],
      fetcher: StubMediaFetcher(result: .success(Data("<!DOCTYPE html>".utf8)))
    )

    // when
    await harness.router.handle(rawUpdate: photoUpdate(id: 1, from: 42))

    // then
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [ImageMessageFailure.undecodable.ownerReplyText])
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func theWiredPairSharesOneCacheFromDepositToReplay() async throws {
    // given — the production seam: one cache, the router built from the runner it wired
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStack(
      writer: queue,
      outcome: .respond("a cat"),
      images: ImageMessageService(
        media: StubMediaFetcher(result: .success(ImageFixtures.jpeg)),
        logger: TestLog.silent
      )
    )

    // when — one photo goes in the front door and the lane runs the turn it dispatched
    let outcome = await stack.router.handle(
      rawUpdate: photoUpdate(id: 1, from: stack.chatId, caption: "Что это?")
    )
    await stack.provider.waitForRequestCount(1)

    // then — the bytes the router deposited came back out of the runner's replay, on exactly one
    // message: two ends, one cache
    #expect(outcome == .processed)
    let request = try #require(await stack.provider.requests.first)
    let carrying = request.filter { message in
      message.content.images.isEmpty == false
    }
    #expect(carrying.count == 1)
    #expect(carrying.first?.content.images == [fetched])
  }

  @Test func shutdownCancellationLeavesThePhotoUpdateUnclaimedForRedelivery() async throws {
    // given — a download parked mid-flight when graceful shutdown cancels the intake task
    let harness = try makeHarness(allowed: [42], fetcher: ParkUntilCancelledFetcher())
    let update = photoUpdate(id: 1, from: 42)

    // when — the poller task is cancelled while the photo is still being downloaded
    let intake = Task {
      await harness.router.handle(rawUpdate: update)
    }
    intake.cancel()
    let outcome = await intake.value

    // then — a no-claim retry: nothing sent, no turn, the update left for the re-poll …
    #expect(outcome == .transientFailure)
    #expect(await harness.transport.sent.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)

    // … so the post-restart redelivery produces the turn the first delivery never did. Required
    // before the dispatch wait, which is unbounded by design: a regression that drops the redelivery
    // must fail here rather than hang waiting for a turn that will never come.
    let redelivered = await harness.router.handle(rawUpdate: update)
    #expect(redelivered == .processed)
    await harness.dispatcher.waitForCalls(atLeast: 1)
    let call = try #require(await harness.dispatcher.calls.first)
    #expect(await harness.cache.images(sessionId: call.sessionId).isEmpty == false)
  }
}
