import ClawAgent
import ClawCore
import ClawData
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

/// A `SessionMessageStore` whose persist reports a full disk, to drive the storage-full path.
struct FullSessions: SessionMessageStore {
  func loadOrCreateSession(sessionKey: String, now: Date) throws -> Int64 {
    throw StoreError.diskFull
  }
  func claimAndPersistInbound(_ inbound: InboundMessage) throws -> ClaimResult {
    throw StoreError.diskFull
  }
  func loadContext(
    sessionId: Int64,
    throughMessageId: Int64,
    limit: Int
  ) throws -> [StoredMessage] {
    []
  }
  func resetWindowAndDetaint(sessionId: Int64, now: Date) throws {}
}

@Suite struct MessageRouterTests {
  private struct Harness {
    let router: MessageRouter
    let transport: RecordingTransport
    let dispatcher: FakeTurnRunner
    let sessionMessages: SessionMessageStoreGRDB
    let runs: RunStoreGRDB
    let queue: DatabaseQueue
  }

  private struct SeededRun {
    let sessionId: Int64
    let runId: Int64
    let messageId: Int64
  }

  private func makeHarness(allowed: [Int64]) throws -> Harness {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: allowed)

    let transport = RecordingTransport()
    let dispatcher = FakeTurnRunner()
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: sessionMessages,
      commands: CommandStoreGRDB(writer: queue),
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist),
      transport: transport,
      turnRunner: dispatcher,
      lanes: SessionLaneRegistry(),
      logger: Logger(label: "test")
    )

    return Harness(
      router: router,
      transport: transport,
      dispatcher: dispatcher,
      sessionMessages: sessionMessages,
      runs: runs,
      queue: queue
    )
  }

  @Test func allowlistedTextDispatchesATurnAndPersistsTheMessage() async throws {
    // given
    let harness = try makeHarness(allowed: [42])

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "hello"))
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then — a turn was dispatched, nothing was sent directly, and the user message was persisted
    #expect(outcome == .processed)
    let calls = await harness.dispatcher.calls
    #expect(calls.count == 1)
    let sent = await harness.transport.sent
    #expect(sent.isEmpty)
    let firstCall = try #require(calls.first)
    let history = try harness.sessionMessages.loadContext(
      sessionId: firstCall.sessionId,
      throughMessageId: firstCall.triggerMessageId,
      limit: 50
    )
    #expect(history.contains { $0.role == .user && $0.content == "hello" })
  }

  @Test func duplicateTextDispatchesOnlyOnce() async throws {
    // given
    let harness = try makeHarness(allowed: [42])

    // when — the same update_id arrives twice
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "hi"))
    await harness.dispatcher.waitForCalls(atLeast: 1)
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "hi"))

    // then — the fused claim dedups, so only one turn runs
    #expect(await harness.dispatcher.calls.count == 1)
  }

  @Test func unknownSenderGetsPrivateBotReply() async throws {
    // given
    let harness = try makeHarness(allowed: [42])

    // when
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "let me in"))

    // then
    let sent = await harness.transport.sent
    #expect(sent.count == 1)
    let reply = try #require(sent.first)
    #expect(reply.text.contains("private bot"))
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func unknownSenderStartEchoesTheirOwnId() async throws {
    // given
    let harness = try makeHarness(allowed: [42])

    // when
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "/start"))

    // then — echoes THEIR id, never the allowlist
    let sent = await harness.transport.sent
    #expect(sent.count == 1)
    let reply = try #require(sent.first)
    #expect(reply.text.contains("7"))
    #expect(reply.text.contains("42") == false)
  }

  @Test func allowlistedStartGetsWelcomeNotATurn() async throws {
    // given
    let harness = try makeHarness(allowed: [42])

    // when
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "/start"))

    // then — a welcome reply, not a dispatched turn
    let sent = await harness.transport.sent
    #expect(sent.count == 1)
    let reply = try #require(sent.first)
    #expect(reply.text.contains("private bot") == false)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func allowlistedStopCancelsActiveRunAndSendsStopped() async throws {
    // given
    let harness = try makeHarness(allowed: [42])
    let seeded = try seedPendingRun(harness, updateId: 10, text: "working")
    #expect(try harness.runs.pickUp(runId: seeded.runId, now: Date(timeIntervalSince1970: 10)))

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 11, from: 42, text: "/stop")
    )

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [CommandReplies.stopped])
    #expect(await harness.dispatcher.calls.isEmpty)
    #expect(try messageCount(harness.queue, content: "/stop") == 0)
    #expect(try runStates(harness.queue)[seeded.runId] == RunState.cancelled.rawValue)
  }

  @Test func allowlistedStopWithNoActiveRunSendsNothingToStop() async throws {
    // given
    let harness = try makeHarness(allowed: [42])

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 20, from: 42, text: "/stop")
    )

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [CommandReplies.nothingToStop])
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func allowlistedNewForThisBotSendsFreshAckAndDoesNotDispatch() async throws {
    // given
    let harness = try makeHarness(allowed: [42])

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 30, from: 42, text: "/new@claw_bot")
    )

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [CommandReplies.freshConversation])
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func newForSomeOtherBotIsPlainTextAndDispatchesTurn() async throws {
    // given
    let harness = try makeHarness(allowed: [42])

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 40, from: 42, text: "/new@some_other_bot")
    )
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.isEmpty)
    let calls = await harness.dispatcher.calls
    let firstCall = try #require(calls.first)
    let history = try harness.sessionMessages.loadContext(
      sessionId: firstCall.sessionId,
      throughMessageId: firstCall.triggerMessageId,
      limit: 50
    )
    #expect(history.contains { $0.role == .user && $0.content == "/new@some_other_bot" })
  }

  @Test func commandAckFailureStillProcessesAndKeepsDurableStopEffect() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: [42])
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let claim = try sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: 50,
        sessionKey: SessionKey.telegramDM(chatId: 42),
        chatId: 42,
        userId: 42,
        text: "working",
        isEdited: false,
        ts: Date(timeIntervalSince1970: 50)
      )
    )
    let runId = try #require(claim.runId)
    #expect(try runs.pickUp(runId: runId, now: Date(timeIntervalSince1970: 51)))
    let transport = RecordingTransport(sendError: .transport("ack down"))
    let dispatcher = FakeTurnRunner()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: sessionMessages,
      commands: CommandStoreGRDB(writer: queue),
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist),
      transport: transport,
      turnRunner: dispatcher,
      lanes: SessionLaneRegistry(),
      logger: Logger(label: "test")
    )

    // when
    let outcome = await router.handle(rawUpdate: textUpdate(id: 52, from: 42, text: "/stop"))

    // then
    #expect(outcome == .processed)
    #expect(await transport.sendAttempts == 1)
    #expect(await dispatcher.calls.isEmpty)
    #expect(try runStates(queue)[runId] == RunState.cancelled.rawValue)
  }

  @Test func unsupportedMediaGetsFriendlyReply() async throws {
    // given
    let harness = try makeHarness(allowed: [42])
    let photo = RawUpdate(
      updateId: 1,
      message: RawMessage(
        messageId: 1,
        fromUserId: 42,
        chatId: 42,
        text: nil,
        caption: nil,
        mediaKind: "photos"
      ),
      editedMessage: nil
    )

    // when
    await harness.router.handle(rawUpdate: photo)

    // then
    let sent = await harness.transport.sent
    let reply = try #require(sent.first)
    #expect(reply.text == "I can't read photos yet.")
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func diskFullOnPersistSendsNoticeAndSignalsStorageFull() async throws {
    // given — the fused persist reports a full disk
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: [42])
    let transport = RecordingTransport()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: FullSessions(),
      commands: CommandStoreGRDB(writer: queue),
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist),
      transport: transport,
      turnRunner: FakeTurnRunner(),
      lanes: SessionLaneRegistry(),
      logger: Logger(label: "test")
    )

    // when
    let outcome = await router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "hello"))

    // then — the owner gets the storage-full notice and the poller is told to back off
    #expect(outcome == .storageFull)
    let sent = await transport.sent
    #expect(sent.contains { $0.text == Degradation.storageFull })
  }

  private func seedPendingRun(
    _ harness: Harness,
    updateId: Int64,
    text: String
  ) throws -> SeededRun {
    let claim = try harness.sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: updateId,
        sessionKey: SessionKey.telegramDM(chatId: 42),
        chatId: 42,
        userId: 42,
        text: text,
        isEdited: false,
        ts: Date(timeIntervalSince1970: Double(updateId))
      )
    )
    return SeededRun(
      sessionId: try #require(claim.sessionId),
      runId: try #require(claim.runId),
      messageId: try #require(claim.triggerMessageId)
    )
  }

  private func runStates(_ queue: DatabaseQueue) throws -> [Int64: String] {
    try queue.read { db in
      let rows = try Row.fetchAll(db, sql: "SELECT id, state FROM runs")
      return Dictionary(
        uniqueKeysWithValues: rows.map { row in (row["id"] as Int64, row["state"] as String) }
      )
    }
  }

  private func messageCount(_ queue: DatabaseQueue, content: String) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages WHERE content = ?",
        arguments: [content]
      ) ?? 0
    }
  }
}
