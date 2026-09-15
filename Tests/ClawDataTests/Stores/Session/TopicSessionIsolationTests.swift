import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

/// One forum supergroup uses an independent session for each topic, including General.
@Suite
struct TopicSessionIsolationTests {
  private func freshStore() throws -> SessionMessageStoreGRDB {
    let queue = try TestDatabase.make()
    return SessionMessageStoreGRDB(writer: queue)
  }

  private func inbound(updateID: Int64, sessionKey: String, chatID: Int64, text: String)
    -> InboundMessage
  {
    InboundMessage(
      updateID: updateID,
      sessionKey: sessionKey,
      chatID: chatID,
      userID: 500,
      text: text,
      isEdited: false,
      ts: Date(timeIntervalSince1970: 100)
    )
  }

  @Test
  func twoTopicsInOneChatAreTwoIndependentSessions() throws {
    // given — one supergroup, two topics and the General topic
    let store = try freshStore()
    let chatID: Int64 = -1_001_234
    let first = SessionKey.telegramTopic(chatID: chatID, threadID: 5)
    let second = SessionKey.telegramTopic(chatID: chatID, threadID: 6)
    let general = SessionKey.telegramTopic(chatID: chatID, threadID: nil)

    // when
    let firstClaim = try store.claimAndPersistInbound(
      inbound(updateID: 1, sessionKey: first, chatID: chatID, text: "about swift")
    )
    let secondClaim = try store.claimAndPersistInbound(
      inbound(updateID: 2, sessionKey: second, chatID: chatID, text: "about lunch")
    )
    let generalClaim = try store.claimAndPersistInbound(
      inbound(updateID: 3, sessionKey: general, chatID: chatID, text: "announcements")
    )

    // then — three sessions, and each window holds only its own topic's message
    let firstID = try #require(firstClaim.sessionID)
    let secondID = try #require(secondClaim.sessionID)
    let generalID = try #require(generalClaim.sessionID)
    #expect(Set([firstID, secondID, generalID]).count == 3)

    let firstSnapshot = try store.loadContextSnapshot(
      sessionID: firstID,
      throughMessageID: try #require(firstClaim.triggerMessageID),
      limit: 10
    )
    #expect(firstSnapshot.sessionKey == first)
    #expect(
      firstSnapshot.history == [
        StoredMessage(role: .user, content: "about swift", provenance: .trusted),
      ]
    )
  }
}
