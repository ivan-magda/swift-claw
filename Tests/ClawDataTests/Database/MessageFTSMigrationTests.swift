import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct MessageFTSMigrationTests {
  private func insertSession(_ db: Database, key: String, at when: Date) throws -> Int64 {
    try db.execute(
      sql:
        "INSERT INTO sessions(session_key, created_ts, updated_ts, tainted) VALUES (?, ?, ?, 0)",
      arguments: [key, when, when]
    )
    return db.lastInsertedRowID
  }

  private func insertMessage(
    _ db: Database,
    sessionId: Int64,
    content: String,
    at when: Date
  ) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO messages(session_id, role, content, provenance, ts)
        VALUES (?, 'user', ?, 'trusted', ?)
        """,
      arguments: [sessionId, content, when]
    )
    return db.lastInsertedRowID
  }

  @Test func ftsRowidEqualsMessageId() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let when = Date(timeIntervalSince1970: 10)

    // when
    let messageId = try queue.write { db -> Int64 in
      let sessionId = try insertSession(db, key: "k", at: when)
      return try insertMessage(db, sessionId: sessionId, content: "hello recall world", at: when)
    }

    // then
    let ftsRowid = try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'recall'"
      )
    }
    #expect(ftsRowid == messageId)
  }

  @Test func deletingAMessageRemovesItsFtsRow() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let when = Date(timeIntervalSince1970: 20)
    let messageId = try queue.write { db -> Int64 in
      let sessionId = try insertSession(db, key: "k", at: when)
      return try insertMessage(db, sessionId: sessionId, content: "ephemeral token here", at: when)
    }

    // when
    try queue.write { db in
      try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [messageId])
    }

    // then - the sync trigger drops the matching FTS row.
    let hits = try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'ephemeral'"
      ) ?? -1
    }
    #expect(hits == 0)
  }

  @Test func messageInsertedBeforeV4IsSearchableAfterInitialPopulation() throws {
    // given - migrate only up to v3, insert a message, then run v4 to build + backfill the index.
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrator.migrate(queue, upTo: "v3")
    let when = Date(timeIntervalSince1970: 30)
    let messageId = try queue.write { db -> Int64 in
      let sessionId = try insertSession(db, key: "k", at: when)
      return try insertMessage(
        db,
        sessionId: sessionId,
        content: "preexisting backfill row",
        at: when
      )
    }

    // when
    try ClawDatabase.migrate(queue)  // runs v4: synchronize(withTable:) backfills existing rows

    // then
    let ftsRowid = try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'backfill'"
      )
    }
    #expect(ftsRowid == messageId)
  }
}
