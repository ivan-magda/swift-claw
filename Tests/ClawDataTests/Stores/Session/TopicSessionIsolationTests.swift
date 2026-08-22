import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

/// One forum supergroup, several topics: the topic is part of the session identity, so a topic's
/// history never appears in a sibling's context and every consumer can recover the mode and the
/// topic from the snapshot alone.
@Suite struct TopicSessionIsolationTests {
  private func freshStore() throws -> SessionMessageStoreGRDB {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return SessionMessageStoreGRDB(writer: queue)
  }

  private func inbound(
    updateId: Int64,
    sessionKey: String,
    chatId: Int64,
    text: String
  ) -> InboundMessage {
    InboundMessage(
      updateId: updateId,
      sessionKey: sessionKey,
      chatId: chatId,
      userId: 500,
      text: text,
      isEdited: false,
      ts: Date(timeIntervalSince1970: 100)
    )
  }

  @Test func twoTopicsInOneChatAreTwoIndependentSessions() throws {
    // given — one supergroup, two topics and the General topic
    let store = try freshStore()
    let chatId: Int64 = -1_001_234
    let first = SessionKey.telegramTopic(chatId: chatId, threadId: 5)
    let second = SessionKey.telegramTopic(chatId: chatId, threadId: 6)
    let general = SessionKey.telegramTopic(chatId: chatId, threadId: nil)

    // when
    let firstClaim = try store.claimAndPersistInbound(
      inbound(updateId: 1, sessionKey: first, chatId: chatId, text: "about swift")
    )
    let secondClaim = try store.claimAndPersistInbound(
      inbound(updateId: 2, sessionKey: second, chatId: chatId, text: "about lunch")
    )
    let generalClaim = try store.claimAndPersistInbound(
      inbound(updateId: 3, sessionKey: general, chatId: chatId, text: "announcements")
    )

    // then — three sessions, and each window holds only its own topic's message
    let firstId = try #require(firstClaim.sessionId)
    let secondId = try #require(secondClaim.sessionId)
    let generalId = try #require(generalClaim.sessionId)
    #expect(Set([firstId, secondId, generalId]).count == 3)

    let firstSnapshot = try store.loadContextSnapshot(
      sessionId: firstId,
      throughMessageId: try #require(firstClaim.triggerMessageId),
      limit: 10
    )
    #expect(
      firstSnapshot.history == [
        StoredMessage(role: .user, content: "about swift", provenance: .trusted)
      ]
    )
  }

  @Test func theSnapshotCarriesTheKeyEveryConsumerDerivesTheModeAndTopicFrom() throws {
    // given
    let store = try freshStore()
    let chatId: Int64 = -1_001_234
    let topicKey = SessionKey.telegramTopic(chatId: chatId, threadId: 5)
    let claim = try store.claimAndPersistInbound(
      inbound(updateId: 1, sessionKey: topicKey, chatId: chatId, text: "about swift")
    )

    // when
    let snapshot = try store.loadContextSnapshot(
      sessionId: try #require(claim.sessionId),
      throughMessageId: try #require(claim.triggerMessageId),
      limit: 10
    )

    // then
    #expect(snapshot.sessionKey == topicKey)
    #expect(SessionKey.mode(from: snapshot.sessionKey) == .group)
    #expect(SessionKey.threadId(from: snapshot.sessionKey) == 5)
  }

  @Test func aDMSnapshotStillReadsAsDirectWithNoTopic() throws {
    // given
    let store = try freshStore()
    let dmKey = SessionKey.telegramDM(chatId: 42)
    let claim = try store.claimAndPersistInbound(
      inbound(updateId: 1, sessionKey: dmKey, chatId: 42, text: "hello")
    )

    // when
    let snapshot = try store.loadContextSnapshot(
      sessionId: try #require(claim.sessionId),
      throughMessageId: try #require(claim.triggerMessageId),
      limit: 10
    )

    // then
    #expect(snapshot.sessionKey == dmKey)
    #expect(SessionKey.mode(from: snapshot.sessionKey) == .direct)
    #expect(SessionKey.threadId(from: snapshot.sessionKey) == nil)
  }

  @Test func anUnknownSessionYieldsTheNarrowestMode() throws {
    // given — a session id with no row (unreachable through the run path; the fail-safe matters)
    let store = try freshStore()

    // when
    let snapshot = try store.loadContextSnapshot(
      sessionId: 9_999,
      throughMessageId: 1,
      limit: 10
    )

    // then
    #expect(snapshot.sessionKey.isEmpty)
    #expect(SessionKey.mode(from: snapshot.sessionKey) == .direct)
  }
}
