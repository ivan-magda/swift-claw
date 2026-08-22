import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

/// The owner's durable state is not the room's. Both families that write it — memory and the
/// schedule table — are refused in a topic before their handler runs, so nothing parks there and
/// the next plain line an attendee types can only ever be a message.
@Suite struct GroupCommandRefusalTests {
  private struct Harness {
    let router: MessageRouter
    let transport: RecordingTransport
    let dispatcher: FakeTurnRunner
    let sessionMessages: SessionMessageStoreGRDB
    let pendingConfirmations: PendingConfirmationRegistry
    let queue: DatabaseQueue

    func replyTexts() async -> [String] {
      await transport.sent.map(\.text)
    }

    func scheduledJobCount() throws -> Int {
      try queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduled_jobs") ?? -1
      }
    }

    func memoryItemCount() throws -> Int {
      try queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items") ?? -1
      }
    }
  }

  private static let groupChatId: Int64 = -1_001
  private static let topicId: Int64 = 5

  private func makeHarness(
    routerSessionMessages: ((SessionMessageStoreGRDB) -> any SessionMessageStore)? = nil
  ) throws -> Harness {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: [42])

    let transport = RecordingTransport()
    let dispatcher = FakeTurnRunner()
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let pendingConfirmations = PendingConfirmationRegistry()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: routerSessionMessages?(sessionMessages) ?? sessionMessages,
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: pendingConfirmations,
      botIdentity: BotIdentity(id: 900, username: "claw_bot"),
      accessControl: AccessControl(allowlist: allowlist, groupChats: [Self.groupChatId]),
      delivery: transport,
      turnRunner: dispatcher,
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
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
      queue: queue
    )
  }

  private func groupUpdate(id: Int64, text: String) -> RawUpdate {
    textUpdate(
      id: id,
      from: 7,
      chat: Self.groupChatId,
      text: text,
      chatKind: .supergroup,
      messageThreadId: Self.topicId,
      senderDisplayName: "Ada"
    )
  }

  /// The whole owner-scoped surface, spelled out: both memory verbs and every schedule verb,
  /// including the bare and `@handle` spellings a room is likeliest to type.
  private static let ownerScopedCommands = [
    "/remember the wifi password is hunter2",
    "/memory",
    "/memory list",
    "/schedule remind me at 9am to open the room",
    "/schedule list",
    "/schedule@claw_bot",
    "/pause 1",
    "/resume 1",
    "/runnow 1",
    "/cancel 1",
  ]

  @Test(arguments: ownerScopedCommands)
  func anOwnerScopedCommandIsRefusedInATopic(command: String) async throws {
    // given
    let harness = try makeHarness()

    // when
    let outcome = await harness.router.handle(rawUpdate: groupUpdate(id: 1, text: command))

    // then — one short refusal, no turn, and nothing durable written
    #expect(outcome == .processed)
    #expect(await harness.replyTexts() == [CommandReplies.directOnly])
    #expect(await harness.dispatcher.calls.isEmpty)
    #expect(try harness.memoryItemCount() == 0)
    #expect(try harness.scheduledJobCount() == 0)
  }

  @Test(arguments: ownerScopedCommands)
  func anOwnerScopedCommandIsUnchangedInADM(command: String) async throws {
    // given
    let harness = try makeHarness()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: command)
    )

    // then — the DM answer is whatever it has always been; only the refusal must be absent
    #expect(outcome == .processed)
    let replies = await harness.replyTexts()
    #expect(replies.isEmpty == false)
    #expect(replies.contains(CommandReplies.directOnly) == false)
  }

  @Test func aRefusedTopicCommandParksNoConfirmation() async throws {
    // given — the /remember spelling that parks a confirmation in a DM
    let harness = try makeHarness()

    // when
    await harness.router.handle(
      rawUpdate: groupUpdate(id: 1, text: "/remember the wifi password is hunter2")
    )

    // then — the handler that would register one was never reached, so the topic has no session
    // to park against at all
    let topicKey = SessionKey.telegramTopic(
      chatId: Self.groupChatId,
      threadId: Self.topicId
    )
    #expect(try harness.sessionMessages.findSession(sessionKey: topicKey) == nil)
  }

  @Test func aDMRememberStillParksItsConfirmation() async throws {
    // given
    let harness = try makeHarness()

    // when
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember I take my coffee black")
    )

    // then
    let sessionId = try #require(
      try harness.sessionMessages.findSession(sessionKey: SessionKey.telegramDM(chatId: 42))
    )
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) != nil)
  }

  /// A store whose only broken operation is the confirmation lookup: reaching the resolver is
  /// then a `.transientFailure` nothing else in the router produces for plain text.
  private func harnessWithBrokenPendingLookup() throws -> Harness {
    try makeHarness(routerSessionMessages: { real in
      FakeSessionMessageStore(
        failures: [.findSession: .unexpected("pending lookup is down")],
        delegatingTo: real
      )
    })
  }

  @Test func aTopicLineIsNeverOfferedToTheConfirmationResolver() async throws {
    // given
    let harness = try harnessWithBrokenPendingLookup()

    // when — an addressed plain line in the room
    let outcome = await harness.router.handle(
      rawUpdate: groupUpdate(id: 1, text: "@claw_bot yes")
    )

    // then — the broken lookup was never called, so the turn ran
    await harness.dispatcher.waitForCalls(atLeast: 1)
    #expect(outcome == .processed)
    #expect(await harness.dispatcher.calls.count == 1)
  }

  @Test func aDMLineIsStillOfferedToTheConfirmationResolver() async throws {
    // given — the same broken lookup, in the conversation that does resolve confirmations
    let harness = try harnessWithBrokenPendingLookup()

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "yes"))

    // then — the DM path fails closed on the lookup it must not guess at
    #expect(outcome == .transientFailure)
    #expect(await harness.dispatcher.calls.isEmpty)
  }
}
