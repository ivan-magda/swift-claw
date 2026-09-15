import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

/// Overheard group chatter: the topic's transcript grows, but nothing is owed back, so the write
/// that keeps the message must not create the run that would answer it. Dedup is the run path's,
/// because both claim the same update key.
@Suite
struct ObservedMessageStoreTests {
  private struct Fixture {
    let store: SessionMessageStoreGRDB
    let queue: DatabaseQueue
  }

  private func freshStore() throws -> Fixture {
    let queue = try TestDatabase.make()
    return Fixture(store: SessionMessageStoreGRDB(writer: queue), queue: queue)
  }

  private func inbound(updateID: Int64, text: String, provenance: Provenance = .trusted)
    -> InboundMessage
  {
    InboundMessage(
      updateID: updateID,
      sessionKey: SessionKey.telegramTopic(chatID: -1_001_234, threadID: 5),
      chatID: -1_001_234,
      userID: 500,
      text: text,
      isEdited: false,
      provenance: provenance,
      telegramMessageID: updateID,
      ts: Date(timeIntervalSince1970: 100)
    )
  }

  private func counts(_ queue: DatabaseQueue) throws -> (messages: Int, runs: Int, sessions: Int) {
    try queue.read { db in
      (
        messages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? -1,
        runs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs") ?? -1,
        sessions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? -1
      )
    }
  }

  @Test
  func anObservedMessageIsStoredWithNoRunBehindIt() throws {
    // given
    let fixture = try freshStore()

    // when
    let result = try fixture.store.claimAndPersistObserved(
      inbound(updateID: 1, text: "anyone else stuck on the wifi")
    )

    // then — claimed, session and message written, and no run to answer it
    #expect(result.newlyClaimed)
    #expect(result.runID == nil)
    #expect(result.triggerMessageID == nil)
    let sessionID = try #require(result.sessionID)
    let messageID = try #require(result.messageID)
    #expect(try counts(fixture.queue) == (messages: 1, runs: 0, sessions: 1))

    let snapshot = try fixture.store.loadContextSnapshot(
      sessionID: sessionID,
      throughMessageID: messageID,
      limit: 10
    )
    #expect(
      snapshot.history == [
        StoredMessage(role: .user, content: "anyone else stuck on the wifi", provenance: .trusted),
      ]
    )
    #expect(snapshot.sessionKey == SessionKey.telegramTopic(chatID: -1_001_234, threadID: 5))
  }

  @Test
  func aRedeliveredObservedUpdateStoresNothingTwice() throws {
    // given
    let fixture = try freshStore()
    _ = try fixture.store.claimAndPersistObserved(inbound(updateID: 1, text: "first"))

    // when — the poller redelivers the same update
    let again = try fixture.store.claimAndPersistObserved(inbound(updateID: 1, text: "first"))

    // then
    #expect(again.newlyClaimed == false)
    #expect(again.sessionID == nil)
    #expect(again.messageID == nil)
    #expect(try counts(fixture.queue) == (messages: 1, runs: 0, sessions: 1))
  }

  @Test
  func anObservedUpdateSharesTheClaimKeyWithTheRunPath() throws {
    // given — the update was already answered
    let fixture = try freshStore()
    _ = try fixture.store.claimAndPersistInbound(inbound(updateID: 1, text: "@claw_bot hello"))

    // when — the same update arrives again, this time down the observe path
    let observed = try fixture.store.claimAndPersistObserved(
      inbound(updateID: 1, text: "@claw_bot hello")
    )

    // then — one claim key, so the message is not stored a second time
    #expect(observed.newlyClaimed == false)
    #expect(try counts(fixture.queue) == (messages: 1, runs: 1, sessions: 1))
  }

  @Test
  func anObservedUntrustedMessageStillTaintsItsSession() throws {
    // given
    let fixture = try freshStore()

    // when
    let result = try fixture.store.claimAndPersistObserved(
      inbound(updateID: 1, text: "spoken words", provenance: .untrusted)
    )

    // then — observing does not launder provenance; the tier and the taint are the run path's
    let snapshot = try fixture.store.loadContextSnapshot(
      sessionID: try #require(result.sessionID),
      throughMessageID: try #require(result.messageID),
      limit: 10
    )
    #expect(snapshot.history.map(\.provenance) == [.untrusted])
    #expect(snapshot.isTainted)
  }
}
