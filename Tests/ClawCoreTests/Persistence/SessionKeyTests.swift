import Foundation
import Testing

@testable import ClawCore

@Suite
struct SessionKeyTests {
  private func message(chatID: Int64, threadID: Int64?) -> IncomingMessage {
    IncomingMessage(
      updateID: 1,
      messageID: 2,
      userID: 3,
      chatID: chatID,
      content: .text("hi"),
      isEdited: false,
      chatKind: threadID == nil ? .private : .supergroup,
      messageThreadID: threadID
    )
  }

  @Test
  func syntheticFormsRenderAndNeverResolveAChatID() {
    // given / when / then — delivery targets live on the job row / in config, never in the key
    // (preamble Global Constraints); chatId(from:) must stay nil for both synthetic forms.
    #expect(SessionKey.scheduledJob(id: 7) == "sched:job:7")
    #expect(SessionKey.heartbeat == "sched:heartbeat")
    #expect(SessionKey.chatID(from: SessionKey.scheduledJob(id: 7)) == nil)
    #expect(SessionKey.chatID(from: SessionKey.heartbeat) == nil)
  }

  @Test
  func telegramDMKeysStillRoundTrip() {
    // given / when / then — the existing form is untouched
    #expect(SessionKey.telegramDM(chatID: 42) == "tg:dm:42")
    #expect(SessionKey.chatID(from: SessionKey.telegramDM(chatID: 42)) == 42)
  }

  @Test
  func topicKeysCarryTheChatAndTheTopicApart() {
    // given / when
    let first = SessionKey.telegramTopic(chatID: -1_001_234, threadID: 5)
    let second = SessionKey.telegramTopic(chatID: -1_001_234, threadID: 6)

    // then — one chat, two topics, two sessions; the negative chat id survives the round trip
    #expect(first == "tg:topic:-1001234:5")
    #expect(first != second)
    #expect(SessionKey.chatID(from: first) == -1_001_234)
    #expect(SessionKey.threadID(from: first) == 5)
    #expect(SessionKey.threadID(from: second) == 6)
  }

  @Test
  func theGeneralTopicHasItsOwnStableKeyThatNoThreadIDCanCollideWith() {
    // given / when — the General topic carries no message_thread_id
    let general = SessionKey.telegramTopic(chatID: -1_001_234, threadID: nil)

    // then — stable, chat-resolvable, thread-less, and distinct from every numeric topic
    #expect(general == "tg:topic:-1001234:general")
    #expect(general == SessionKey.telegramTopic(chatID: -1_001_234, threadID: nil))
    #expect(SessionKey.chatID(from: general) == -1_001_234)
    #expect(SessionKey.threadID(from: general) == nil)
    #expect(general != SessionKey.telegramTopic(chatID: -1_001_234, threadID: 0))
    #expect(general != SessionKey.telegramTopic(chatID: -1_001_234, threadID: 1))
  }

  @Test
  func modeIsGroupOnlyForATopicKey() {
    // given / when / then — every owner-facing session reads .direct
    #expect(SessionKey.mode(from: SessionKey.telegramTopic(chatID: -7, threadID: 5)) == .group)
    #expect(SessionKey.mode(from: SessionKey.telegramTopic(chatID: -7, threadID: nil)) == .group)
    #expect(SessionKey.mode(from: SessionKey.telegramDM(chatID: 42)) == .direct)
    #expect(SessionKey.mode(from: SessionKey.scheduledJob(id: 7)) == .direct)
    #expect(SessionKey.mode(from: SessionKey.heartbeat) == .direct)
    #expect(SessionKey.mode(from: "") == .direct)
  }

  @Test
  func threadIDIsNilForEveryNonTopicKey() {
    // given / when / then
    #expect(SessionKey.threadID(from: SessionKey.telegramDM(chatID: 42)) == nil)
    #expect(SessionKey.threadID(from: SessionKey.scheduledJob(id: 7)) == nil)
    #expect(SessionKey.threadID(from: SessionKey.heartbeat) == nil)
    #expect(SessionKey.threadID(from: "") == nil)
  }

  @Test
  func theMessageHelperHonorsTheModeRatherThanTheWireChatKind() {
    // given — the same topic-carrying message resolved in each mode
    let inTopic = message(chatID: -1_001_234, threadID: 9)

    // when / then — .direct never leaks a topic into the key, .group always carries it
    #expect(SessionKey.telegram(for: inTopic, mode: .direct) == "tg:dm:-1001234")
    #expect(SessionKey.telegram(for: inTopic, mode: .group) == "tg:topic:-1001234:9")
    #expect(
      SessionKey.telegram(for: message(chatID: -1_001_234, threadID: nil), mode: .group)
        == "tg:topic:-1001234:general"
    )
  }
}
