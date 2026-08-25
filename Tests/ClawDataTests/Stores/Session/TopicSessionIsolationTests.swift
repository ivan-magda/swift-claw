import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

/// One forum supergroup uses an independent session for each topic, including General.
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
    #expect(firstSnapshot.sessionKey == first)
    #expect(
      firstSnapshot.history == [
        StoredMessage(role: .user, content: "about swift", provenance: .trusted)
      ]
    )
  }
}
