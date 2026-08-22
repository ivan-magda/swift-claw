import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V10MigrationTests {
  private static let seededAt = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Legacy Upgrade

  @Test func vTenAddsTheTelegramAddressingColumnsWithoutTouchingExistingRows() throws {
    // given — a populated v9 database, i.e. rows written before the columns existed
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVNine(queue)

    // when
    try ClawDatabase.migrate(queue)

    // then — the run survives with a null Telegram trigger id
    let runs = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM runs ORDER BY id")
    }
    #expect(runs.count == 1)
    #expect(runs[0]["id"] == 1)
    #expect(runs[0]["state"] == "DONE")
    #expect(runs[0]["trigger_message_id"] == 1)
    #expect((runs[0]["trigger_telegram_message_id"] as Int64?) == nil)

    // and the delivery survives with null topic and reply-target columns
    let deliveries = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM outbound_deliveries ORDER BY step_index")
    }
    #expect(deliveries.count == 1)
    #expect(deliveries[0]["chat_id"] == 7)
    #expect(deliveries[0]["payload"] == "already delivered")
    #expect((deliveries[0]["message_thread_id"] as Int64?) == nil)
    #expect((deliveries[0]["reply_to_message_id"] as Int64?) == nil)
  }

  @Test func vTenColumnsAcceptAnExplicitValue() throws {
    // given — a migrated database
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVNine(queue)
    try ClawDatabase.migrate(queue)

    // when — a row is written carrying the new addressing values
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_telegram_message_id)
          VALUES (1, 'PENDING', ?, ?, 4242)
          """,
        arguments: [Self.seededAt, Self.seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
            payload_hash, status, created_ts, message_thread_id, reply_to_message_id)
          VALUES (1, 1, 7, 'dedup-2', 'topic reply', 'hash-2', 'PENDING', ?, 99, 4242)
          """,
        arguments: [Self.seededAt]
      )
    }

    // then — both round-trip
    let stored = try queue.read { db in
      (
        run: try Int64.fetchOne(
          db,
          sql: "SELECT trigger_telegram_message_id FROM runs WHERE state = 'PENDING'"
        ),
        thread: try Int64.fetchOne(
          db,
          sql: "SELECT message_thread_id FROM outbound_deliveries WHERE step_index = 1"
        ),
        replyTo: try Int64.fetchOne(
          db,
          sql: "SELECT reply_to_message_id FROM outbound_deliveries WHERE step_index = 1"
        )
      )
    }
    #expect(stored.run == 4242)
    #expect(stored.thread == 99)
    #expect(stored.replyTo == 4242)
  }

  // MARK: - Claim Transaction

  @Test func theFusedClaimStampsTheTelegramMessageIdOnTheRun() throws {
    // given — a group inbound carrying the Telegram message id that addressed the bot
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)

    // when
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramTopic(chatId: -100, threadId: 12),
        chatId: -100,
        userId: 7,
        text: "@clawd what is the schedule",
        isEdited: false,
        telegramMessageId: 8080,
        ts: Self.seededAt
      )
    )

    // then — the run carries it, written by the claim itself rather than a follow-up update
    let stored = try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT trigger_telegram_message_id FROM runs WHERE id = ?",
        arguments: [claim.runId]
      )
    }
    #expect(stored == 8080)
  }

  @Test func aDirectMessageRunStoresItsTelegramMessageIdToo() throws {
    // given — the DM path, which needs the same reply target for its own sends
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)

    // when
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 2,
        sessionKey: SessionKey.telegramDM(chatId: 7),
        chatId: 7,
        userId: 7,
        text: "hello",
        isEdited: false,
        telegramMessageId: 512,
        ts: Self.seededAt
      )
    )

    // then
    let stored = try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT trigger_telegram_message_id FROM runs WHERE id = ?",
        arguments: [claim.runId]
      )
    }
    #expect(stored == 512)
  }

  @Test func anInboundWithoutATelegramMessageIdLeavesTheColumnNull() throws {
    // given — a non-Telegram origin (a scheduled job's synthetic inbound)
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)

    // when
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 3,
        sessionKey: SessionKey.scheduledJob(id: 4),
        chatId: 7,
        userId: 7,
        text: "fire",
        isEdited: false,
        ts: Self.seededAt
      )
    )

    // then
    let stored = try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT trigger_telegram_message_id FROM runs WHERE id = ?",
        arguments: [claim.runId]
      )
    }
    #expect(stored == nil)
  }
}

// MARK: - Legacy Fixtures

private extension V10MigrationTests {
  /// A v9 database holding the two rows v10 alters: a run and an outbound delivery.
  static func seedVNine(_ queue: DatabaseQueue) throws {
    try ClawDatabase.migrator.migrate(queue, upTo: "v9")
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES ('tg:dm:7', ?, ?, 0)
          """,
        arguments: [seededAt, seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts)
          VALUES (1, NULL, 'user', 'find the plan', 'trusted', ?)
          """,
        arguments: [seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_message_id)
          VALUES (1, 'DONE', ?, ?, 1)
          """,
        arguments: [seededAt, seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
            payload_hash, status, created_ts)
          VALUES (1, 0, 7, 'dedup-1', 'already delivered', 'hash-1', 'SENT', ?)
          """,
        arguments: [seededAt]
      )
    }
  }
}
