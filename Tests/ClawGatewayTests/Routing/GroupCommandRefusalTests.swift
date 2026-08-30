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

  @Test func anOwnerScopedCommandIsRefusedBeforeItCanParkAConfirmation() async throws {
    // given — the /remember spelling that would park a confirmation in a DM
    let harness = try makeHarness()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: groupUpdate(id: 1, text: "/remember the wifi password is hunter2")
    )

    // then — one short refusal, no turn, no durable effect, and no session to park against
    #expect(outcome == .processed)
    #expect(await harness.replyTexts() == [CommandReplies.directOnly])
    #expect(await harness.dispatcher.calls.isEmpty)
    #expect(try harness.memoryItemCount() == 0)
    #expect(try harness.scheduledJobCount() == 0)
    let topicKey = SessionKey.telegramTopic(
      chatId: Self.groupChatId,
      threadId: Self.topicId
    )
    #expect(try harness.sessionMessages.findSession(sessionKey: topicKey) == nil)
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
}
