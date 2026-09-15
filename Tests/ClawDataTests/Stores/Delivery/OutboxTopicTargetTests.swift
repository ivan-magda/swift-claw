import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

/// An outbox row is stamped with its destination at enqueue, from the run itself. Nothing at
/// delivery time knows which topic asked — the dispatcher drains long after the router is gone,
/// and after a restart there is no router at all.
@Suite
struct OutboxTopicTargetTests {
  private struct Fixture {
    let outbox: OutboxStoreGRDB
    let runs: RunStoreGRDB
    let sessionID: Int64
    let runID: Int64
  }

  private static let groupChatID: Int64 = -1_001
  private static let triggerMessageID: Int64 = 88

  private func fixture(sessionKey: String, chatID: Int64, telegramMessageID: Int64?) throws
    -> Fixture
  {
    let queue = try TestDatabase.make()
    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: sessionKey,
        chatID: chatID,
        userID: 7,
        text: "what is the schedule",
        isEdited: false,
        telegramMessageID: telegramMessageID,
        ts: Date()
      )
    )
    let runs = RunStoreGRDB(writer: queue)
    let runID = try #require(claim.runID)
    _ = try #require(try runs.pickUp(runID: runID, now: Date()))
    return Fixture(
      outbox: OutboxStoreGRDB(writer: queue),
      runs: runs,
      sessionID: try #require(claim.sessionID),
      runID: runID
    )
  }

  private func commitReply(_ fixture: Fixture, chatID: Int64) throws {
    let committed = try fixture.runs.commitAssistantTurn(
      AssistantTurn(
        runID: fixture.runID,
        sessionID: fixture.sessionID,
        chatID: chatID,
        content: "the talk starts at 10",
        usage: makeProviderUsage(
          runID: fixture.runID,
          sessionID: fixture.sessionID,
          model: "test-model"
        ),
        chunks: [
          OutboxChunk(
            stepIndex: 0,
            chatID: chatID,
            payload: "the talk starts at 10",
            payloadHash: "r1"
          ),
        ]
      ),
      now: Date()
    )
    #expect(committed == .committed)
  }

  @Test
  func aTopicRunsReplyCarriesItsTopicAndItsReplyTarget() throws {
    // given — a run triggered by message 88 in topic 5 of a forum supergroup
    let fixture = try fixture(
      sessionKey: SessionKey.telegramTopic(chatID: Self.groupChatID, threadID: 5),
      chatID: Self.groupChatID,
      telegramMessageID: Self.triggerMessageID
    )

    // when
    try commitReply(fixture, chatID: Self.groupChatID)

    // then
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(
      row.target
        == DeliveryTarget(
          chatID: Self.groupChatID,
          messageThreadID: 5,
          replyToMessageID: Self.triggerMessageID
        )
    )
  }

  @Test
  func aGeneralTopicRunsReplyCarriesAReplyTargetButNoThread() throws {
    // given — the General topic, whose messages carry no thread id
    let fixture = try fixture(
      sessionKey: SessionKey.telegramTopic(chatID: Self.groupChatID, threadID: nil),
      chatID: Self.groupChatID,
      telegramMessageID: Self.triggerMessageID
    )

    // when
    try commitReply(fixture, chatID: Self.groupChatID)

    // then
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(row.messageThreadID == nil)
    #expect(row.replyToMessageID == Self.triggerMessageID)
  }

  /// A crash notice is the one enqueue with no turn behind it: the boot sweep mints it from the
  /// run row alone, so a topic session's notice can only find its way home through the key.
  @Test
  func aTopicRunsBootNoticeLandsInItsTopic() throws {
    // given — a run left RUNNING in topic 5 by a crash, nothing delivered
    let fixture = try fixture(
      sessionKey: SessionKey.telegramTopic(chatID: Self.groupChatID, threadID: 5),
      chatID: Self.groupChatID,
      telegramMessageID: Self.triggerMessageID
    )

    // when
    let replies = try fixture.runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "unfinished",
      heartbeatNoticeChatID: nil
    )

    // then — the notice targets the group, and its row carries the topic and the message that asked
    #expect(
      replies == [
        DegradationReply(chatID: Self.groupChatID, runID: fixture.runID, text: "unfinished"),
      ]
    )
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(
      row.target
        == DeliveryTarget(
          chatID: Self.groupChatID,
          messageThreadID: 5,
          replyToMessageID: Self.triggerMessageID
        )
    )
  }

  @Test
  func aDirectRunsBootNoticeCarriesNoTopic() throws {
    // given
    let fixture = try fixture(
      sessionKey: SessionKey.telegramDM(chatID: 42),
      chatID: 42,
      telegramMessageID: Self.triggerMessageID
    )

    // when
    let replies = try fixture.runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "unfinished",
      heartbeatNoticeChatID: nil
    )

    // then — the DM notice is the whole-chat target it was before topics existed
    #expect(replies == [DegradationReply(chatID: 42, runID: fixture.runID, text: "unfinished")])
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(row.target == .chat(42))
  }

  @Test
  func aDirectRunsReplyCarriesNeither() throws {
    // given
    let fixture = try fixture(
      sessionKey: SessionKey.telegramDM(chatID: 42),
      chatID: 42,
      telegramMessageID: Self.triggerMessageID
    )

    // when
    try commitReply(fixture, chatID: 42)

    // then — the DM row is exactly the whole-chat target it was before topics existed
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(row.target == .chat(42))
  }

  /// A scheduled job's session key holds no chat id, so its target can only ever be the chat the
  /// chunk names — the reply-target lookup must not turn that into a nil-chat row.
  @Test
  func aScheduledJobsReplyCarriesTheChunksChat() throws {
    // given
    let fixture = try fixture(
      sessionKey: SessionKey.scheduledJob(id: 3),
      chatID: 42,
      telegramMessageID: nil
    )

    // when
    try commitReply(fixture, chatID: 42)

    // then
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(row.target == .chat(42))
  }
}
