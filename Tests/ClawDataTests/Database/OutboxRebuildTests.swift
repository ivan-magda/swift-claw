import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct OutboxRebuildTests {
  private static let seededAt = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func vElevenCarriesEveryDeliveredRowAcrossTheRebuildAsRunSourced() throws {
    // given — a populated v10 database, i.e. rows written while run_id was still NOT NULL
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVTen(queue)

    // when
    try ClawDatabase.migrate(queue)

    // then — the delivery survives whole, and its provenance defaults to the run that owns it
    let deliveries = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM outbound_deliveries ORDER BY step_index")
    }
    #expect(deliveries.count == 1)
    #expect(deliveries[0]["run_id"] == 1)
    #expect(deliveries[0]["dedup_key"] == "1:0")
    #expect(deliveries[0]["payload"] == "already delivered")
    #expect(deliveries[0]["telegram_message_id"] == 555)
    #expect(deliveries[0]["status"] == "SENT")
    #expect(deliveries[0]["approval_id"] == nil)
    #expect(deliveries[0]["delivery_source"] == DeliverySource.run.rawValue)
  }

  @Test func aRunlessNoticeIsAcceptedAndReadBackWithoutARun() throws {
    // given — the shape the pre-v11 NOT NULL made unwritable
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let outbox = OutboxStoreGRDB(writer: queue)

    // when
    let claimed = try outbox.claimNotice(Self.notice(subjectDigest: "abc", ordinal: 0))

    // then — the row exists, decodes, and names itself by its delivery key rather than a run
    #expect(claimed)
    let row = try #require(try outbox.pendingOutbound().first)
    #expect(row.runId == nil)
    #expect(row.deliveryKey == "learning:abc:0")
    #expect(row.originLabel == DeliverySource.learning.rawValue)
    #expect(row.payload == "candidate ready")
  }

  @Test func reclaimingTheSameNoticeChunkDoesNotDuplicateIt() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let outbox = OutboxStoreGRDB(writer: queue)
    #expect(try outbox.claimNotice(Self.notice(subjectDigest: "abc", ordinal: 0)))

    // when — the same subject and ordinal are enqueued again after a retry
    let second = try outbox.claimNotice(Self.notice(subjectDigest: "abc", ordinal: 0))

    // then
    #expect(second == false)
    #expect(try outbox.pendingOutbound().count == 1)
  }

  @Test func aRunSourcedRowMayNeverLoseItsRun() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)

    // when — a row keeps the default 'run' provenance but names no run
    let write = {
      try queue.write { db in
        try db.execute(
          sql: """
            INSERT INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
              payload_hash, status, created_ts)
            VALUES (NULL, 0, 7, 'orphan', 'x', 'h', 'PENDING', ?)
            """,
          arguments: [Self.seededAt]
        )
      }
    }

    // then — the table refuses it, so a runless row can only exist as a declared notice
    #expect(throws: DatabaseError.self, performing: write)
  }
}

// MARK: - Fixtures

private extension OutboxRebuildTests {
  static func notice(subjectDigest: String, ordinal: Int) -> LearningNoticeChunk {
    LearningNoticeChunk(
      subjectDigest: subjectDigest,
      ordinal: ordinal,
      chatId: 7,
      payload: "candidate ready",
      payloadHash: "hash"
    )
  }

  /// A v10 database holding the one delivery row the v11 rebuild has to carry across.
  static func seedVTen(_ queue: DatabaseQueue) throws {
    try ClawDatabase.migrator.migrate(queue, upTo: "v10")
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
          INSERT INTO runs(session_id, state, created_ts, updated_ts)
          VALUES (1, 'DONE', ?, ?)
          """,
        arguments: [seededAt, seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
            payload_hash, telegram_message_id, status, created_ts, sent_ts)
          VALUES (1, 0, 7, '1:0', 'already delivered', 'hash-1', 555, 'SENT', ?, ?)
          """,
        arguments: [seededAt, seededAt]
      )
    }
  }
}
