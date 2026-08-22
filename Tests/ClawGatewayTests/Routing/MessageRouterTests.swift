import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

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

  private func makeHarness(
    allowed: [Int64],
    groupChats: Set<Int64> = [],
    doctor: any DoctorReporting = StubDoctorReporter(),
    logger: Logger = TestLog.silent
  ) throws -> Harness {
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
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist, groupChats: groupChats),
      delivery: transport,
      turnRunner: dispatcher,
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      coordinator: ApprovalCoordinator(),
      doctor: doctor,
      logger: logger
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
    let history = try harness.sessionMessages.loadContextSnapshot(
      sessionId: firstCall.sessionId,
      throughMessageId: firstCall.triggerMessageId,
      limit: 50
    ).history
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

  @Test func messageSentOnBehalfOfAChatIsSkippedWithItsOwnReason() async throws {
    // given — an anonymous admin post: normalization drops it, and the log has to say why
    let capture = RecordingLogCapture()
    let harness = try makeHarness(allowed: [42], logger: capture.logger())
    let onBehalfOfTheGroup = RawUpdate(
      updateId: 9,
      message: RawMessage(
        messageId: 9,
        fromUserId: 1_087_968_824,
        chatId: -1_001_234,
        text: "announcement",
        caption: nil,
        mediaKind: nil,
        chatKind: .supergroup,
        hasSenderChat: true
      ),
      editedMessage: nil
    )

    // when
    let outcome = await harness.router.handle(rawUpdate: onBehalfOfTheGroup)

    // then — skipped, silent, and distinguishable from a generic empty update
    #expect(outcome == .skipped)
    #expect(await harness.transport.sent.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)
    let reasons = capture.entries.map(\.message)
    #expect(reasons.contains { $0.contains("sent on behalf of a chat") })
    #expect(reasons.allSatisfy { !$0.contains("nothing actionable") })
  }

  @Test func nonAllowlistedSenderPersistsNoRunOrMessage() async throws {
    // given — the sender's id (7) is never seeded into the allowlist
    let harness = try makeHarness(allowed: [42])

    // when — a stranger sends plain text
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "let me in"))

    // then — fail-closed: no turn dispatched and nothing durable is written for the stranger
    #expect(await harness.dispatcher.calls.isEmpty)
    #expect(try runStates(harness.queue).isEmpty)
    #expect(try messageCount(harness.queue, content: "let me in") == 0)
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

  @Test func unlistedGroupMessageSendsNothingAndLogsTheChatId() async throws {
    // given — the bot was added to a group nobody put in CLAW_GROUP_CHATS
    let capture = RecordingLogCapture()
    let harness = try makeHarness(allowed: [42], logger: capture.logger())

    // when — even the owner writes there
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(
        id: 1,
        from: 42,
        chat: -1_001,
        text: "hello",
        chatKind: .supergroup,
        chatTitle: "Podlodka iOS Crew"
      )
    )

    // then — silence in the room, but a trace the operator can read the chat id out of
    #expect(outcome == .skipped)
    #expect(await harness.transport.sent.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)
    let logged = try #require(capture.entries.first { entry in entry.level == .info })
    #expect(logged.message.contains("-1001"))
    #expect(logged.message.contains("Podlodka iOS Crew"))
  }

  @Test func anUntitledUnlistedGroupStillLogsItsChatId() async throws {
    // given
    let capture = RecordingLogCapture()
    let harness = try makeHarness(allowed: [42], logger: capture.logger())

    // when — Telegram sent no title
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, chat: -1_002, text: "hi", chatKind: .group)
    )

    // then
    let logged = try #require(capture.entries.first { entry in entry.level == .info })
    #expect(logged.message.contains("-1002"))
    #expect(await harness.transport.sent.isEmpty)
  }

  @Test func allowlistedGroupTextIsRouted() async throws {
    // given
    let harness = try makeHarness(allowed: [42], groupChats: [-1_001])

    // when — an attendee who is on no allowlist writes in the configured group
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 7, chat: -1_001, text: "hello", chatKind: .supergroup)
    )
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then — chat membership was the proof; nothing was refused
    #expect(outcome == .processed)
    #expect(await harness.dispatcher.calls.count == 1)
    #expect(await harness.transport.sent.isEmpty)
  }

  @Test func aChannelPostIsRefusedEvenFromAnAllowlistedChat() async throws {
    // given — the same id is configured, but the update arrives as a channel
    let harness = try makeHarness(allowed: [42], groupChats: [-1_001])

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, chat: -1_001, text: "hi", chatKind: .channel)
    )

    // then
    #expect(outcome == .skipped)
    #expect(await harness.transport.sent.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func aStrangersGroupStartIsNeverAnsweredWithTheirUserId() async throws {
    // given
    let harness = try makeHarness(allowed: [42])

    // when — /start in a group the bot was dragged into
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 7, chat: -1_003, text: "/start", chatKind: .supergroup)
    )

    // then — the DM-only enrollment hint never leaks into a room
    #expect(await harness.transport.sent.isEmpty)
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
    _ = try #require(
      try harness.runs.pickUp(runId: seeded.runId, now: Date(timeIntervalSince1970: 10))
    )

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
    let history = try harness.sessionMessages.loadContextSnapshot(
      sessionId: firstCall.sessionId,
      throughMessageId: firstCall.triggerMessageId,
      limit: 50
    ).history
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
    _ = try #require(try runs.pickUp(runId: runId, now: Date(timeIntervalSince1970: 51)))
    let transport = RecordingTransport(sendError: .transport("ack down"))
    let dispatcher = FakeTurnRunner()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: sessionMessages,
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist),
      delivery: transport,
      turnRunner: dispatcher,
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      logger: TestLog.silent
    )

    // when
    let outcome = await router.handle(rawUpdate: textUpdate(id: 52, from: 42, text: "/stop"))

    // then
    #expect(outcome == .processed)
    #expect(await transport.sendAttempts == 1)
    #expect(await dispatcher.calls.isEmpty)
    #expect(try runStates(queue)[runId] == RunState.cancelled.rawValue)
  }

  @Test func failedNewAckDoesNotUndoCommittedEffect() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: [42])
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let firstClaim = try sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: 60,
        sessionKey: SessionKey.telegramDM(chatId: 42),
        chatId: 42,
        userId: 42,
        text: "running",
        isEdited: false,
        ts: Date(timeIntervalSince1970: 60)
      )
    )
    let runningRunId = try #require(firstClaim.runId)
    _ = try #require(try runs.pickUp(runId: runningRunId, now: Date(timeIntervalSince1970: 61)))
    let secondClaim = try sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: 61,
        sessionKey: SessionKey.telegramDM(chatId: 42),
        chatId: 42,
        userId: 42,
        text: "queued",
        isEdited: false,
        ts: Date(timeIntervalSince1970: 61)
      )
    )
    let queuedRunId = try #require(secondClaim.runId)
    let transport = RecordingTransport(sendError: .transport("ack down"))
    let dispatcher = FakeTurnRunner()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: sessionMessages,
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist),
      delivery: transport,
      turnRunner: dispatcher,
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      logger: TestLog.silent
    )

    // when
    let outcome = await router.handle(rawUpdate: textUpdate(id: 62, from: 42, text: "/new"))

    // then
    #expect(outcome == .processed)
    #expect(await transport.sendAttempts == 1)
    #expect(await dispatcher.calls.isEmpty)
    #expect(try messageCount(queue, content: "/new") == 0)
    let states = try runStates(queue)
    #expect(states[runningRunId] == RunState.superseded.rawValue)
    #expect(states[queuedRunId] == RunState.superseded.rawValue)
  }

  @Test func allowlistedDoctorSendsHealthSummary() async throws {
    // given — a stub reporter standing in for the daemon's live health report
    var report = DoctorReport()
    report.add(key: "db.writable", value: "true", group: .database)
    let harness = try makeHarness(allowed: [42], doctor: StubDoctorReporter(stubbed: report))

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/doctor")
    )

    // then — the compact summary is sent, and no turn is dispatched
    #expect(outcome == .processed)
    let reply = try #require(await harness.transport.sent.first)
    #expect(reply.text.contains("all systems healthy"))
    #expect(reply.text.contains("Database: ok"))
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func allowlistedMCPSendsOnlyTheMCPSectionOfTheHealthReport() async throws {
    // given — a report carrying both an MCP row and an unrelated one
    var report = DoctorReport()
    report.add(key: "db.writable", value: "true", group: .database)
    report.add(key: "mcp.linear.tools", value: "skipped: unreachable", ok: false, group: .mcp)
    let harness = try makeHarness(allowed: [42], doctor: StubDoctorReporter(stubbed: report))

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/mcp")
    )

    // then — status only: the reply renders the snapshot the daemon already holds, and no turn runs
    #expect(outcome == .processed)
    let reply = try #require(await harness.transport.sent.first)
    #expect(reply.text.contains("MCP: FAIL"))
    #expect(reply.text.contains("mcp.linear.tools: skipped: unreachable"))
    #expect(reply.text.contains("db.writable") == false)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func mcpArgumentsAreIgnoredSoNoChatMessageCanManageAServer() async throws {
    // given
    var report = DoctorReport()
    report.add(key: "mcp", value: "no servers configured", group: .mcp)
    let harness = try makeHarness(allowed: [42], doctor: StubDoctorReporter(stubbed: report))

    // when — an argument tail shaped like a management verb
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/mcp set-token linear hunter2")
    )

    // then — it is answered as the same status request, and nothing was dispatched
    #expect(outcome == .processed)
    let reply = try #require(await harness.transport.sent.first)
    #expect(reply.text.contains("mcp: no servers configured"))
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func allowlistedSkillsUsesAFreshScanAndDoesNotDispatchATurn() async throws {
    // given
    let firstScan = SkillScanResult(
      descriptors: [skillDescriptor(name: "alpha", description: "First skill.")],
      warnings: []
    )
    let secondScan = SkillScanResult(
      descriptors: [skillDescriptor(name: "bravo", description: "Second skill.")],
      warnings: [.invalidSkillManifest(skill: "broken")]
    )
    let doctor = StubDoctorReporter(skillScans: [firstScan, secondScan])
    let harness = try makeHarness(allowed: [42], doctor: doctor)

    // when
    let firstOutcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/skills")
    )
    let secondOutcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "/skills details")
    )

    // then
    #expect(firstOutcome == .processed)
    #expect(secondOutcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.count == 2)
    #expect(sent[0].text.contains(WorkspaceSkills.indexLine(for: firstScan.descriptors[0])))
    #expect(sent[0].text.contains("broken") == false)
    #expect(sent[1].text.contains(WorkspaceSkills.indexLine(for: secondScan.descriptors[0])))
    #expect(sent[1].text.contains(secondScan.warnings[0].ownerFacingReason))
    #expect(await harness.dispatcher.calls.isEmpty)
    #expect(try messageCount(harness.queue, content: "/skills") == 0)
  }

  @Test func duplicateSkillsUpdateSendsDiagnosticsOnlyOnce() async throws {
    // given
    let scan = SkillScanResult(
      descriptors: [skillDescriptor(name: "alpha", description: "First skill.")],
      warnings: []
    )
    let harness = try makeHarness(
      allowed: [42],
      doctor: StubDoctorReporter(skillScans: [scan])
    )
    let update = textUpdate(id: 1, from: 42, text: "/skills")

    // when
    let firstOutcome = await harness.router.handle(rawUpdate: update)
    let duplicateOutcome = await harness.router.handle(rawUpdate: update)

    // then
    #expect(firstOutcome == .processed)
    #expect(duplicateOutcome == .skipped)
    #expect(await harness.transport.sent.count == 1)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func nonAllowlistedSkillsRevealsNoSkillDiagnostics() async throws {
    // given
    let scan = SkillScanResult(
      descriptors: [skillDescriptor(name: "private-skill", description: "Owner only.")],
      warnings: [.invalidSkillManifest(skill: "private-broken")]
    )
    let harness = try makeHarness(
      allowed: [42],
      doctor: StubDoctorReporter(skillScans: [scan])
    )

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 7, text: "/skills")
    )

    // then
    #expect(outcome == .processed)
    let reply = try #require(await harness.transport.sent.first)
    #expect(reply.text == MessageRouter.privateBotText)
    #expect(reply.text.contains("private-skill") == false)
    #expect(reply.text.contains("private-broken") == false)
    #expect(await harness.dispatcher.calls.isEmpty)
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
    #expect(reply.text == MessageRouter.unsupportedMediaText(kind: "photos"))
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
      sessionMessages: FakeSessionMessageStore.failingEverything(with: .diskFull),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist),
      delivery: transport,
      turnRunner: FakeTurnRunner(),
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      logger: TestLog.silent
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

  private func skillDescriptor(name: String, description: String) -> SkillDescriptor {
    SkillDescriptor(
      name: name,
      description: description,
      directory: URL(fileURLWithPath: "/tmp/skills/\(name)")
    )
  }
}
