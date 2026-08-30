import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

/// Two events the daemon can only observe: its own membership changing, and Telegram replacing a
/// group's chat id under it. Neither reaches a session, both leave a trace the operator can act on.
@Suite struct MembershipEventRoutingTests {
  private struct Harness {
    let router: MessageRouter
    let transport: RecordingTransport
    let dispatcher: FakeTurnRunner
    let capture: RecordingLogCapture

    func messages(atLeast level: Logger.Level) -> [String] {
      capture.entries.filter { entry in entry.level >= level }.map(\.message)
    }
  }

  private static let groupChatId: Int64 = -1_001
  private static let migratedChatId: Int64 = -1_001_999

  private func makeHarness() throws -> Harness {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: [42])

    let transport = RecordingTransport()
    let dispatcher = FakeTurnRunner()
    let capture = RecordingLogCapture()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botIdentity: BotIdentity(id: 900, username: "claw_bot"),
      accessControl: AccessControl(allowlist: allowlist, groupChats: [Self.groupChatId]),
      delivery: transport,
      turnRunner: dispatcher,
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      logger: capture.logger()
    )
    return Harness(
      router: router,
      transport: transport,
      dispatcher: dispatcher,
      capture: capture
    )
  }

  private func membershipUpdate(
    id: Int64 = 1,
    chatId: Int64 = MembershipEventRoutingTests.groupChatId,
    title: String? = "Podlodka iOS Crew",
    from old: ChatMembershipStatus,
    to new: ChatMembershipStatus
  ) -> RawUpdate {
    RawUpdate(
      updateId: id,
      message: nil,
      editedMessage: nil,
      myChatMember: RawChatMemberUpdate(
        chatId: chatId,
        chatKind: .supergroup,
        chatTitle: title,
        actorUserId: 42,
        actorDisplayName: "Ada Lovelace",
        oldStatus: old,
        newStatus: new
      )
    )
  }

  private func migrationUpdate(id: Int64 = 1) -> RawUpdate {
    RawUpdate(
      updateId: id,
      message: RawMessage(
        messageId: id,
        fromUserId: 42,
        chatId: Self.groupChatId,
        text: nil,
        caption: nil,
        mediaKind: nil,
        chatKind: .group,
        chatTitle: "Podlodka iOS Crew",
        migratedToChatId: Self.migratedChatId
      ),
      editedMessage: nil
    )
  }

  @Test func beingAddedToARoomIsLoggedWithItsChatId() async throws {
    // given
    let harness = try makeHarness()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: membershipUpdate(from: .left, to: .member)
    )

    // then — observed only: nothing sent, no turn, and the id an operator needs is in the log
    #expect(outcome == .skipped)
    #expect(await harness.transport.sent.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)
    let logged = try #require(harness.capture.entries.first { $0.message.contains("added") })
    #expect(logged.message.contains("-1001"))
    #expect(logged.message.contains("Podlodka iOS Crew"))
  }

  @Test func beingRemovedFromARoomIsLoggedAsARemoval() async throws {
    // given
    let harness = try makeHarness()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: membershipUpdate(from: .member, to: .kicked)
    )

    // then
    #expect(outcome == .skipped)
    let logged = try #require(harness.capture.entries.first { $0.message.contains("removed") })
    #expect(logged.message.contains("kicked"))
  }

  @Test func aRightsChangeIsLoggedWithBothStatuses() async throws {
    // given — the promotion that gives a bot in a privacy-mode group its message access
    let harness = try makeHarness()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: membershipUpdate(from: .member, to: .administrator)
    )

    // then
    #expect(outcome == .skipped)
    let logged = try #require(harness.capture.entries.first { $0.message.contains("member") })
    #expect(logged.message.contains("administrator"))
  }

  @Test func anUnlistedRoomsMembershipChangeIsStillLogged() async throws {
    // given — the bot is added to a room nobody put in CLAW_GROUP_CHATS
    let harness = try makeHarness()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: membershipUpdate(chatId: -2_002, from: .left, to: .member)
    )

    // then — the log is the only way to learn the id that would have to be configured
    #expect(outcome == .skipped)
    #expect(harness.capture.entries.contains { $0.message.contains("-2002") })
  }

  @Test func aMigratedGroupLogsAnErrorNamingBothIds() async throws {
    // given — Telegram upgraded the configured group to a supergroup with a NEW id
    let harness = try makeHarness()

    // when
    let outcome = await harness.router.handle(rawUpdate: migrationUpdate())

    // then — loud, actionable, and never silently re-pointed at the new id
    #expect(outcome == .skipped)
    #expect(await harness.transport.sent.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)
    let errors = harness.messages(atLeast: .error)
    let migration = try #require(errors.first { $0.contains("supergroup") })
    #expect(migration.contains("-1001"))
    #expect(migration.contains("-1001999"))
    #expect(migration.contains("CLAW_GROUP_CHATS"))
  }

  @Test func anUpdateKindThisBuildCannotReadIsSkippedQuietly() async throws {
    // given — a decoded update carrying no message, no callback and no membership change
    let harness = try makeHarness()
    let unknown = RawUpdate(updateId: 7, message: nil, editedMessage: nil)

    // when
    let outcome = await harness.router.handle(rawUpdate: unknown)

    // then — the batch survives it: skipped, so the poller may advance past it
    #expect(outcome == .skipped)
    #expect(await harness.transport.sent.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)
    #expect(harness.messages(atLeast: .warning).isEmpty)
  }
}
