import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct RunExecutionContextTests {
  @Test
  func groupRequesterAndOriginalTopicSurviveReload() throws {
    // given
    let queue = try TestDatabase.make()
    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      InboundMessage(
        updateID: 17,
        sessionKey: SessionKey.telegramTopic(chatID: -700, threadID: 19),
        chatID: -700,
        userID: 42,
        text: "inspect the repository",
        isEdited: false,
        telegramMessageID: 53,
        ts: Date()
      )
    )
    let runID = try #require(claim.runID)

    // when
    let restored = try #require(
      try RunStoreGRDB(writer: queue).executionContext(runID: runID, fallbackChatID: 999)
    )

    // then
    #expect(restored.sessionID == claim.sessionID)
    #expect(restored.requesterUserID == 42)
    #expect(restored.mode == .group)
    #expect(restored.origin == .interactive)
    #expect(
      restored.deliveryTarget
        == DeliveryTarget(chatID: -700, messageThreadID: 19, replyToMessageID: 53)
    )
  }

  @Test
  func legacyAndScheduledRequesterRules() throws {
    // given
    let queue = try TestDatabase.make()
    let scenarios: [(String, RunOrigin)] = [
      (SessionKey.telegramDM(chatID: 42), .interactive),
      (SessionKey.telegramTopic(chatID: -700, threadID: nil), .interactive),
      (SessionKey.scheduledJob(id: 9), .scheduled),
    ]
    let runIDs = try queue.write { db in
      try scenarios.map { key, origin in
        try db.execute(
          sql: "INSERT INTO sessions(session_key, created_ts, updated_ts) VALUES (?, ?, ?)",
          arguments: [key, Date(), Date()]
        )
        let sessionID = db.lastInsertedRowID
        try db.execute(
          sql: """
          INSERT INTO runs(session_id, state, origin, requester_user_id, created_ts, updated_ts)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
          arguments: [
            sessionID,
            RunState.pending.rawValue,
            origin.rawValue,
            origin == .scheduled ? 88 : nil,
            Date(),
            Date(),
          ]
        )
        return db.lastInsertedRowID
      }
    }

    // when
    let contexts = try runIDs.map { runID in
      let restored = try RunStoreGRDB(writer: queue).executionContext(
        runID: runID,
        fallbackChatID: 999
      )
      return try #require(restored)
    }

    // then
    #expect(contexts[0].requesterUserID == 42)
    #expect(contexts[1].requesterUserID == nil)
    #expect(contexts[2].requesterUserID == nil)
    #expect(contexts[2].deliveryTarget == .chat(999))
  }

  @Test(arguments: [true, false])
  func malformedInteractiveRoutingFailsClosed(groupPrefixPreserved: Bool) throws {
    // given
    let queue = try TestDatabase.make()
    let key = SessionKey.telegramTopic(chatID: -700, threadID: 19)
    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      InboundMessage(
        updateID: 17,
        sessionKey: key,
        chatID: -700,
        userID: 42,
        text: "inspect the repository",
        isEdited: false,
        ts: Date()
      )
    )
    let runID = try #require(claim.runID)
    let sessionID = try #require(claim.sessionID)
    let invalidKey = groupPrefixPreserved ? key + "invalid" : "invalid-session"
    try queue.write { db in
      try db.execute(
        sql: "UPDATE sessions SET session_key = ? WHERE id = ?",
        arguments: [invalidKey, sessionID]
      )
    }

    // when
    let result = Result {
      try RunStoreGRDB(writer: queue).executionContext(runID: runID, fallbackChatID: -700)
    }

    // then
    #expect(throws: StoreError.self) {
      try result.get()
    }
  }
}
