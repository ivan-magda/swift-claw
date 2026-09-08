import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct RunExecutionContextTests {
  @Test func groupRequesterAndOriginalTopicSurviveReload() throws {
    // given
    let queue = try TestDatabase.make()
    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      InboundMessage(
        updateId: 17,
        sessionKey: SessionKey.telegramTopic(chatId: -700, threadId: 19),
        chatId: -700,
        userId: 42,
        text: "inspect the repository",
        isEdited: false,
        telegramMessageId: 53,
        ts: Date()
      )
    )
    let runId = try #require(claim.runId)

    // when
    let restored = try #require(
      try RunStoreGRDB(writer: queue).executionContext(runId: runId, fallbackChatId: 999)
    )

    // then
    #expect(restored.sessionId == claim.sessionId)
    #expect(restored.requesterUserId == 42)
    #expect(restored.mode == .group)
    #expect(restored.origin == .interactive)
    #expect(
      restored.deliveryTarget
        == DeliveryTarget(chatId: -700, messageThreadId: 19, replyToMessageId: 53)
    )
  }

  @Test func legacyAndScheduledRequesterRules() throws {
    // given
    let queue = try TestDatabase.make()
    let scenarios: [(String, RunOrigin)] = [
      (SessionKey.telegramDM(chatId: 42), .interactive),
      (SessionKey.telegramTopic(chatId: -700, threadId: nil), .interactive),
      (SessionKey.scheduledJob(id: 9), .scheduled),
    ]
    let runIds = try queue.write { db in
      try scenarios.map { key, origin in
        try db.execute(
          sql: "INSERT INTO sessions(session_key, created_ts, updated_ts) VALUES (?, ?, ?)",
          arguments: [key, Date(), Date()]
        )
        let sessionId = db.lastInsertedRowID
        try db.execute(
          sql: """
            INSERT INTO runs(session_id, state, origin, requester_user_id, created_ts, updated_ts)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            sessionId, RunState.pending.rawValue, origin.rawValue,
            origin == .scheduled ? 88 : nil, Date(), Date(),
          ]
        )
        return db.lastInsertedRowID
      }
    }

    // when
    let contexts = try runIds.map { runId in
      let restored = try RunStoreGRDB(writer: queue).executionContext(
        runId: runId,
        fallbackChatId: 999
      )
      return try #require(restored)
    }

    // then
    #expect(contexts[0].requesterUserId == 42)
    #expect(contexts[1].requesterUserId == nil)
    #expect(contexts[2].requesterUserId == nil)
    #expect(contexts[2].deliveryTarget == .chat(999))
  }

  @Test(arguments: [true, false])
  func malformedInteractiveRoutingFailsClosed(groupPrefixPreserved: Bool) throws {
    // given
    let queue = try TestDatabase.make()
    let key = SessionKey.telegramTopic(chatId: -700, threadId: 19)
    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      InboundMessage(
        updateId: 17,
        sessionKey: key,
        chatId: -700,
        userId: 42,
        text: "inspect the repository",
        isEdited: false,
        ts: Date()
      )
    )
    let runId = try #require(claim.runId)
    let sessionId = try #require(claim.sessionId)
    let invalidKey = groupPrefixPreserved ? key + "invalid" : "invalid-session"
    try queue.write { db in
      try db.execute(
        sql: "UPDATE sessions SET session_key = ? WHERE id = ?",
        arguments: [invalidKey, sessionId]
      )
    }

    // when
    let result = Result {
      try RunStoreGRDB(writer: queue).executionContext(runId: runId, fallbackChatId: -700)
    }

    // then
    #expect(throws: StoreError.self) {
      try result.get()
    }
  }
}
