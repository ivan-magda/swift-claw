import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct MemoryCommandStoreTests {
  private struct InjectedCrash: Error {}

  private func freshStore() throws -> (MemoryCommandStoreGRDB, MemoryStoreGRDB, DatabaseQueue) {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return (MemoryCommandStoreGRDB(writer: queue), MemoryStoreGRDB(writer: queue), queue)
  }

  private func auditRows(_ queue: DatabaseQueue) throws -> [Row] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT actor, action, args_redacted, decision FROM audit_events ORDER BY id ASC"
      )
    }
  }

  private func processedCount(_ queue: DatabaseQueue, updateId: Int64) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM processed_updates WHERE update_id = ?",
        arguments: [updateId]
      ) ?? 0
    }
  }

  @Test func applyRememberClaimsInsertsAndAuditsInOneTransaction() throws {
    // given
    let (commands, reads, queue) = try freshStore()
    let now = Date(timeIntervalSince1970: 100)
    let newItem = NewMemoryItem(text: "ship 3a", kind: .project, sessionId: nil)

    // when
    let result = try commands.applyRemember(updateId: 10, item: newItem, now: now)

    // then
    #expect(result.newlyClaimed)
    let stored = try #require(result.item)
    #expect(stored.text == "ship 3a")
    #expect(stored.kind == .project)
    #expect(try reads.get(id: stored.id)?.text == "ship 3a")
    #expect(try processedCount(queue, updateId: 10) == 1)

    let audits = try auditRows(queue)
    #expect(audits.count == 1)
    let audit = try #require(audits.first)
    #expect(audit["action"] as String == AuditAction.memoryWrite.rawValue)
    #expect(audit["actor"] as String == AuditActor.owner.rawValue)
    #expect(audit["args_redacted"] as String == "/remember")
  }

  @Test func redeliveredRememberIsSkippedWithNoDoubleWrite() throws {
    // given
    let (commands, _, queue) = try freshStore()
    let now = Date(timeIntervalSince1970: 200)
    let newItem = NewMemoryItem(text: "once", kind: .user, sessionId: nil)
    let first = try commands.applyRemember(updateId: 20, item: newItem, now: now)

    // when - the same update_id arrives again.
    let duplicate = try commands.applyRemember(updateId: 20, item: newItem, now: now)

    // then
    #expect(first.newlyClaimed)
    #expect(duplicate.newlyClaimed == false)
    #expect(duplicate.item == nil)
    let itemCount = try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items") ?? -1
    }
    #expect(itemCount == 1)
    #expect(try auditRows(queue).count == 1)
  }

  @Test func applyForgetClaimsDeletesAndAuditsInOneTransaction() throws {
    // given
    let (commands, reads, queue) = try freshStore()
    let stored = try reads.append(
      NewMemoryItem(text: "forget me", kind: .user, sessionId: nil),
      now: Date(timeIntervalSince1970: 1)
    )

    // when
    let result = try commands.applyForget(
      updateId: 30,
      itemId: stored.id,
      now: Date(timeIntervalSince1970: 2)
    )

    // then
    #expect(result.newlyClaimed)
    #expect(result.item == nil)
    #expect(try reads.get(id: stored.id) == nil)
    #expect(try processedCount(queue, updateId: 30) == 1)

    let audits = try auditRows(queue)
    #expect(audits.count == 1)
    let audit = try #require(audits.first)
    #expect(audit["action"] as String == AuditAction.memoryDelete.rawValue)
    #expect(audit["decision"] as String == "deleted")
  }

  @Test func applyForgetOnMissingItemStillClaimsAndAuditsAbsent() throws {
    // given
    let (commands, _, queue) = try freshStore()

    // when
    let result = try commands.applyForget(
      updateId: 31,
      itemId: 12_345,
      now: Date(timeIntervalSince1970: 2)
    )

    // then
    #expect(result.newlyClaimed)
    #expect(try processedCount(queue, updateId: 31) == 1)
    let audit = try #require(try auditRows(queue).first)
    #expect(audit["action"] as String == AuditAction.memoryDelete.rawValue)
    #expect(audit["decision"] as String == "absent")
  }

  @Test func crashAfterClaimRollsBackClaimAndAllowsRetry() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let crashing = MemoryCommandStoreGRDB(
      writer: queue,
      afterClaimForTesting: { throw InjectedCrash() }
    )
    let now = Date(timeIntervalSince1970: 400)
    let newItem = NewMemoryItem(text: "atomic", kind: .user, sessionId: nil)

    // when
    #expect(throws: InjectedCrash.self) {
      try crashing.applyRemember(updateId: 40, item: newItem, now: now)
    }

    // then - the claim and the insert both rolled back; a retry succeeds cleanly.
    #expect(try processedCount(queue, updateId: 40) == 0)
    let itemCount = try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items") ?? -1
    }
    #expect(itemCount == 0)

    let retry = try MemoryCommandStoreGRDB(writer: queue)
      .applyRemember(updateId: 40, item: newItem, now: now)
    #expect(retry.newlyClaimed)
    #expect(try processedCount(queue, updateId: 40) == 1)
  }
}
