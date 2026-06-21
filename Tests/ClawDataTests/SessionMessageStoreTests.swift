import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct SessionMessageStoreTests {
  private func freshStore() throws -> SessionMessageStoreGRDB {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return SessionMessageStoreGRDB(writer: queue)
  }

  private func inbound(updateId: Int64, chatId: Int64 = 42, text: String) -> InboundMessage {
    InboundMessage(
      updateId: updateId,
      sessionKey: SessionKey.telegramDM(chatId: chatId),
      chatId: chatId,
      userId: chatId,
      text: text,
      isEdited: false,
      ts: Date()
    )
  }

  @Test func claimAndPersistInsertsClaimSessionAndMessageAtomically() throws {
    // given
    let store = try freshStore()

    // when
    let result = try store.claimAndPersistInbound(inbound(updateId: 1, text: "hello"))

    // then
    #expect(result.newlyClaimed)
    let sessionId = try #require(result.sessionId)
    let history = try store.loadRecentMessages(sessionId: sessionId, limit: 10)
    #expect(history == [StoredMessage(role: .user, content: "hello", provenance: .trusted)])
  }

  @Test func duplicateUpdateIsNotReclaimedAndPersistsNothingNew() throws {
    // given
    let store = try freshStore()
    _ = try store.claimAndPersistInbound(inbound(updateId: 1, text: "first"))

    // when — same update_id redelivered
    let again = try store.claimAndPersistInbound(inbound(updateId: 1, text: "first"))

    // then — claim fails, no second message
    #expect(again.newlyClaimed == false)
    #expect(again.sessionId == nil)
  }

  @Test func recentMessagesAreOldestFirstWithinLimit() throws {
    // given
    let store = try freshStore()
    for index in 1...5 {
      _ = try store.claimAndPersistInbound(inbound(updateId: Int64(index), text: "m\(index)"))
    }
    let sessionId = try store.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 42),
      now: Date()
    )

    // when
    let history = try store.loadRecentMessages(sessionId: sessionId, limit: 3)

    // then — the three most recent, oldest-first
    #expect(history.map(\.content) == ["m3", "m4", "m5"])
  }

  @Test func claimAndPersistRollsBackEntirelyWhenTheMessageInsertAborts() throws {
    // given — a trigger that aborts the message INSERT mid-transaction
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try queue.write { db in
      try db.execute(
        sql: "CREATE TRIGGER boom BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'boom'); END"
      )
    }
    let store = SessionMessageStoreGRDB(writer: queue)

    // when / then — the fused write throws and leaves NEITHER the claim NOR the session (F4 atomicity)
    #expect(throws: (any Error).self) {
      try store.claimAndPersistInbound(inbound(updateId: 1, text: "hi"))
    }
    let claims = try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processed_updates")
    }
    let sessions = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions")
    }
    #expect(claims == 0)
    #expect(sessions == 0)
  }
}
