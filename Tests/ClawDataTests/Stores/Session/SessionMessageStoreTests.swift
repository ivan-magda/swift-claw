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

  @Test func claimAndPersistCreatesPendingRunBoundToTriggerMessage() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let store = SessionMessageStoreGRDB(writer: queue)

    // when
    let result = try store.claimAndPersistInbound(inbound(updateId: 1, text: "hello"))

    // then
    #expect(result.newlyClaimed)
    let sessionId = try #require(result.sessionId)
    let messageId = try #require(result.messageId)
    let runId = try #require(result.runId)
    let triggerMessageId = try #require(result.triggerMessageId)
    #expect(triggerMessageId == messageId)

    let history = try store.loadContext(
      sessionId: sessionId,
      throughMessageId: triggerMessageId,
      limit: 10
    )
    #expect(history == [StoredMessage(role: .user, content: "hello", provenance: .trusted)])

    let run = try #require(
      try queue.read { db in
        try Row.fetchOne(
          db,
          sql: "SELECT session_id, state, trigger_message_id FROM runs WHERE id = ?",
          arguments: [runId]
        )
      }
    )
    let persistedSessionId: Int64 = run["session_id"]
    let state: String = run["state"]
    let persistedTriggerMessageId: Int64 = run["trigger_message_id"]
    #expect(persistedSessionId == sessionId)
    #expect(state == RunState.pending.rawValue)
    #expect(persistedTriggerMessageId == messageId)
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

  @Test func loadContextIsOldestFirstWithinLimitAndTriggerBound() throws {
    // given
    let store = try freshStore()
    var claims: [ClaimResult] = []
    for index in 1...5 {
      claims.append(
        try store.claimAndPersistInbound(inbound(updateId: Int64(index), text: "m\(index)"))
      )
    }
    let sessionId = try #require(claims.last?.sessionId)
    let throughMessageId = try #require(claims[3].triggerMessageId)

    // when
    let history = try store.loadContext(
      sessionId: sessionId,
      throughMessageId: throughMessageId,
      limit: 3
    )

    // then — bounded through m4, so m5 is invisible to m4's turn.
    #expect(history.map(\.content) == ["m2", "m3", "m4"])
  }

  @Test func resetWindowAndDetaintExcludesEarlierHistory() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let store = SessionMessageStoreGRDB(writer: queue)
    let first = try store.claimAndPersistInbound(inbound(updateId: 1, text: "before"))
    let sessionId = try #require(first.sessionId)
    try queue.write { db in
      try db.execute(sql: "UPDATE sessions SET tainted = 1 WHERE id = ?", arguments: [sessionId])
    }

    // when
    try store.resetWindowAndDetaint(sessionId: sessionId, now: Date())
    let second = try store.claimAndPersistInbound(inbound(updateId: 2, text: "after"))
    let triggerMessageId = try #require(second.triggerMessageId)
    let history = try store.loadContext(
      sessionId: sessionId,
      throughMessageId: triggerMessageId,
      limit: 10
    )

    // then
    #expect(history.map(\.content) == ["after"])
    let tainted = try #require(
      try queue.read { db in
        try Int.fetchOne(
          db,
          sql: "SELECT tainted FROM sessions WHERE id = ?",
          arguments: [sessionId]
        )
      }
    )
    #expect(tainted == 0)
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
    let claims = try #require(
      try queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processed_updates")
      }
    )
    let sessions = try #require(
      try queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions")
      }
    )
    #expect(claims == 0)
    #expect(sessions == 0)
  }

  @Test func loadContextSnapshotIncludesHistoryIdsWindowStartAndTaint() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let store = SessionMessageStoreGRDB(writer: queue)
    let first = try store.claimAndPersistInbound(inbound(updateId: 1, text: "before"))
    let second = try store.claimAndPersistInbound(inbound(updateId: 2, text: "after"))
    let sessionId = try #require(second.sessionId)
    let firstMessageId = try #require(first.messageId)
    let secondMessageId = try #require(second.messageId)
    let triggerMessageId = try #require(second.triggerMessageId)
    try queue.write { db in
      try db.execute(
        sql: "UPDATE sessions SET window_start_message_id = ?, tainted = 1 WHERE id = ?",
        arguments: [firstMessageId, sessionId]
      )
    }

    // when
    let snapshot = try store.loadContextSnapshot(
      sessionId: sessionId,
      throughMessageId: triggerMessageId,
      limit: 10
    )

    // then
    #expect(snapshot.history.map(\.content) == ["after"])
    #expect(snapshot.historyMessageIds == [secondMessageId])
    #expect(snapshot.windowStartMessageId == firstMessageId)
    #expect(snapshot.isTainted)
  }

  @Test func claimAndPersistRollsBackEntirelyWhenTheRunInsertAborts() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try queue.write { db in
      try db.execute(
        sql: "CREATE TRIGGER boom BEFORE INSERT ON runs BEGIN SELECT RAISE(ABORT, 'boom'); END"
      )
    }
    let store = SessionMessageStoreGRDB(writer: queue)

    // when / then
    #expect(throws: (any Error).self) {
      try store.claimAndPersistInbound(inbound(updateId: 1, text: "hi"))
    }
    let counts = try queue.read { db in
      (
        claims: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processed_updates") ?? -1,
        sessions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? -1,
        messages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? -1,
        runs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs") ?? -1
      )
    }
    #expect(counts.claims == 0)
    #expect(counts.sessions == 0)
    #expect(counts.messages == 0)
    #expect(counts.runs == 0)
  }
}
