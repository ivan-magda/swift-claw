import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

/// An outbox row is stamped with its destination at enqueue, from the run itself. Nothing at
/// delivery time knows which topic asked — the dispatcher drains long after the router is gone,
/// and after a restart there is no router at all.
@Suite struct OutboxTopicTargetTests {
  private struct Fixture {
    let outbox: OutboxStoreGRDB
    let runs: RunStoreGRDB
    let sessionId: Int64
    let runId: Int64
  }

  private static let groupChatId: Int64 = -1_001
  private static let triggerMessageId: Int64 = 88

  private func fixture(
    sessionKey: String,
    chatId: Int64,
    telegramMessageId: Int64?
  ) throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: sessionKey,
        chatId: chatId,
        userId: 7,
        text: "what is the schedule",
        isEdited: false,
        telegramMessageId: telegramMessageId,
        ts: Date()
      )
    )
    let runs = RunStoreGRDB(writer: queue)
    let runId = try #require(claim.runId)
    _ = try #require(try runs.pickUp(runId: runId, now: Date()))
    return Fixture(
      outbox: OutboxStoreGRDB(writer: queue),
      runs: runs,
      sessionId: try #require(claim.sessionId),
      runId: runId
    )
  }

  private func commitReply(_ fixture: Fixture, chatId: Int64) throws {
    let committed = try fixture.runs.commitAssistantTurn(
      AssistantTurn(
        runId: fixture.runId,
        sessionId: fixture.sessionId,
        chatId: chatId,
        content: "the talk starts at 10",
        usage: makeProviderUsage(
          runId: fixture.runId,
          sessionId: fixture.sessionId,
          model: "test-model"
        ),
        chunks: [
          OutboxChunk(
            stepIndex: 0,
            chatId: chatId,
            payload: "the talk starts at 10",
            payloadHash: "r1"
          )
        ]
      ),
      now: Date()
    )
    #expect(committed == .committed)
  }

  @Test func aTopicRunsReplyCarriesItsTopicAndItsReplyTarget() throws {
    // given — a run triggered by message 88 in topic 5 of a forum supergroup
    let fixture = try fixture(
      sessionKey: SessionKey.telegramTopic(chatId: Self.groupChatId, threadId: 5),
      chatId: Self.groupChatId,
      telegramMessageId: Self.triggerMessageId
    )

    // when
    try commitReply(fixture, chatId: Self.groupChatId)

    // then
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(
      row.target
        == DeliveryTarget(
          chatId: Self.groupChatId,
          messageThreadId: 5,
          replyToMessageId: Self.triggerMessageId
        )
    )
  }

  @Test func aGeneralTopicRunsReplyCarriesAReplyTargetButNoThread() throws {
    // given — the General topic, whose messages carry no thread id
    let fixture = try fixture(
      sessionKey: SessionKey.telegramTopic(chatId: Self.groupChatId, threadId: nil),
      chatId: Self.groupChatId,
      telegramMessageId: Self.triggerMessageId
    )

    // when
    try commitReply(fixture, chatId: Self.groupChatId)

    // then
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(row.messageThreadId == nil)
    #expect(row.replyToMessageId == Self.triggerMessageId)
  }

  /// A crash notice is the one enqueue with no turn behind it: the boot sweep mints it from the
  /// run row alone, so a topic session's notice can only find its way home through the key.
  @Test func aTopicRunsBootNoticeLandsInItsTopic() throws {
    // given — a run left RUNNING in topic 5 by a crash, nothing delivered
    let fixture = try fixture(
      sessionKey: SessionKey.telegramTopic(chatId: Self.groupChatId, threadId: 5),
      chatId: Self.groupChatId,
      telegramMessageId: Self.triggerMessageId
    )

    // when
    let replies = try fixture.runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )

    // then — the notice targets the group, and its row carries the topic and the message that asked
    #expect(
      replies == [
        DegradationReply(chatId: Self.groupChatId, runId: fixture.runId, text: "unfinished")
      ]
    )
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(
      row.target
        == DeliveryTarget(
          chatId: Self.groupChatId,
          messageThreadId: 5,
          replyToMessageId: Self.triggerMessageId
        )
    )
  }

  @Test func aDirectRunsBootNoticeCarriesNoTopic() throws {
    // given
    let fixture = try fixture(
      sessionKey: SessionKey.telegramDM(chatId: 42),
      chatId: 42,
      telegramMessageId: Self.triggerMessageId
    )

    // when
    let replies = try fixture.runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )

    // then — the DM notice is the whole-chat target it was before topics existed
    #expect(replies == [DegradationReply(chatId: 42, runId: fixture.runId, text: "unfinished")])
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(row.target == .chat(42))
  }

  @Test func aDirectRunsReplyCarriesNeither() throws {
    // given
    let fixture = try fixture(
      sessionKey: SessionKey.telegramDM(chatId: 42),
      chatId: 42,
      telegramMessageId: Self.triggerMessageId
    )

    // when
    try commitReply(fixture, chatId: 42)

    // then — the DM row is exactly the whole-chat target it was before topics existed
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(row.target == .chat(42))
  }

  /// A scheduled job's session key holds no chat id, so its target can only ever be the chat the
  /// chunk names — the reply-target lookup must not turn that into a nil-chat row.
  @Test func aScheduledJobsReplyCarriesTheChunksChat() throws {
    // given
    let fixture = try fixture(
      sessionKey: SessionKey.scheduledJob(id: 3),
      chatId: 42,
      telegramMessageId: nil
    )

    // when
    try commitReply(fixture, chatId: 42)

    // then
    let row = try #require(try fixture.outbox.pendingOutbound().first)
    #expect(row.target == .chat(42))
  }
}
