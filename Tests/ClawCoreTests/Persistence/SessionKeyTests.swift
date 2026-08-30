import Foundation
import Testing

@testable import ClawCore

@Suite struct SessionKeyTests {
  private func message(chatId: Int64, threadId: Int64?) -> IncomingMessage {
    IncomingMessage(
      updateId: 1,
      messageId: 2,
      userId: 3,
      chatId: chatId,
      content: .text("hi"),
      isEdited: false,
      chatKind: threadId == nil ? .private : .supergroup,
      messageThreadId: threadId
    )
  }

  @Test func syntheticFormsRenderAndNeverResolveAChatId() {
    // given / when / then — delivery targets live on the job row / in config, never in the key
    // (preamble Global Constraints); chatId(from:) must stay nil for both synthetic forms.
    #expect(SessionKey.scheduledJob(id: 7) == "sched:job:7")
    #expect(SessionKey.heartbeat == "sched:heartbeat")
    #expect(SessionKey.chatId(from: SessionKey.scheduledJob(id: 7)) == nil)
    #expect(SessionKey.chatId(from: SessionKey.heartbeat) == nil)
  }

  @Test func telegramDMKeysStillRoundTrip() {
    // given / when / then — the existing form is untouched
    #expect(SessionKey.telegramDM(chatId: 42) == "tg:dm:42")
    #expect(SessionKey.chatId(from: SessionKey.telegramDM(chatId: 42)) == 42)
  }

  @Test func topicKeysCarryTheChatAndTheTopicApart() {
    // given / when
    let first = SessionKey.telegramTopic(chatId: -1_001_234, threadId: 5)
    let second = SessionKey.telegramTopic(chatId: -1_001_234, threadId: 6)

    // then — one chat, two topics, two sessions; the negative chat id survives the round trip
    #expect(first == "tg:topic:-1001234:5")
    #expect(first != second)
    #expect(SessionKey.chatId(from: first) == -1_001_234)
    #expect(SessionKey.threadId(from: first) == 5)
    #expect(SessionKey.threadId(from: second) == 6)
  }

  @Test func theGeneralTopicHasItsOwnStableKeyThatNoThreadIdCanCollideWith() {
    // given / when — the General topic carries no message_thread_id
    let general = SessionKey.telegramTopic(chatId: -1_001_234, threadId: nil)

    // then — stable, chat-resolvable, thread-less, and distinct from every numeric topic
    #expect(general == "tg:topic:-1001234:general")
    #expect(general == SessionKey.telegramTopic(chatId: -1_001_234, threadId: nil))
    #expect(SessionKey.chatId(from: general) == -1_001_234)
    #expect(SessionKey.threadId(from: general) == nil)
    #expect(general != SessionKey.telegramTopic(chatId: -1_001_234, threadId: 0))
    #expect(general != SessionKey.telegramTopic(chatId: -1_001_234, threadId: 1))
  }

  @Test func modeIsGroupOnlyForATopicKey() {
    // given / when / then — every owner-facing session reads .direct
    #expect(SessionKey.mode(from: SessionKey.telegramTopic(chatId: -7, threadId: 5)) == .group)
    #expect(SessionKey.mode(from: SessionKey.telegramTopic(chatId: -7, threadId: nil)) == .group)
    #expect(SessionKey.mode(from: SessionKey.telegramDM(chatId: 42)) == .direct)
    #expect(SessionKey.mode(from: SessionKey.scheduledJob(id: 7)) == .direct)
    #expect(SessionKey.mode(from: SessionKey.heartbeat) == .direct)
    #expect(SessionKey.mode(from: "") == .direct)
  }

  @Test func threadIdIsNilForEveryNonTopicKey() {
    // given / when / then
    #expect(SessionKey.threadId(from: SessionKey.telegramDM(chatId: 42)) == nil)
    #expect(SessionKey.threadId(from: SessionKey.scheduledJob(id: 7)) == nil)
    #expect(SessionKey.threadId(from: SessionKey.heartbeat) == nil)
    #expect(SessionKey.threadId(from: "") == nil)
  }

  @Test func theMessageHelperHonorsTheModeRatherThanTheWireChatKind() {
    // given — the same topic-carrying message resolved in each mode
    let inTopic = message(chatId: -1_001_234, threadId: 9)

    // when / then — .direct never leaks a topic into the key, .group always carries it
    #expect(SessionKey.telegram(for: inTopic, mode: .direct) == "tg:dm:-1001234")
    #expect(SessionKey.telegram(for: inTopic, mode: .group) == "tg:topic:-1001234:9")
    #expect(
      SessionKey.telegram(for: message(chatId: -1_001_234, threadId: nil), mode: .group)
        == "tg:topic:-1001234:general"
    )
  }
}
