import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct MemoryStoreTests {
  private func freshStore() throws -> (MemoryStoreGRDB, DatabaseQueue) {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return (MemoryStoreGRDB(writer: queue), queue)
  }

  @Test func appendThenGetReturnsTheStoredItem() throws {
    // given
    let (store, _) = try freshStore()
    let now = Date(timeIntervalSince1970: 100)
    let newItem = NewMemoryItem(text: "ship increment 3a", kind: .project, sessionId: nil)

    // when
    let appended = try store.append(newItem, now: now)
    let fetched = try store.get(id: appended.id)

    // then
    #expect(appended.id > 0)
    #expect(appended.text == "ship increment 3a")
    #expect(appended.kind == .project)
    #expect(appended.createdAt == now)
    #expect(fetched == appended)
  }

  @Test func getReturnsNilForMissingId() throws {
    // given
    let (store, _) = try freshStore()

    // when / then
    #expect(try store.get(id: 999) == nil)
  }

  @Test func deleteRemovesItemAndReportsWhetherARowWasDeleted() throws {
    // given
    let (store, _) = try freshStore()
    let appended = try store.append(
      NewMemoryItem(text: "forget me", kind: .user, sessionId: nil),
      now: Date(timeIntervalSince1970: 1)
    )

    // when
    let firstDelete = try store.delete(id: appended.id)
    let secondDelete = try store.delete(id: appended.id)

    // then
    #expect(firstDelete)
    #expect(secondDelete == false)
    #expect(try store.get(id: appended.id) == nil)
  }

  @Test func listFiltersByKindMostRecentFirst() throws {
    // given
    let (store, _) = try freshStore()
    _ = try store.append(
      NewMemoryItem(text: "user older", kind: .user, sessionId: nil),
      now: Date(timeIntervalSince1970: 10)
    )
    _ = try store.append(
      NewMemoryItem(text: "project fact", kind: .project, sessionId: nil),
      now: Date(timeIntervalSince1970: 20)
    )
    _ = try store.append(
      NewMemoryItem(text: "user newer", kind: .user, sessionId: nil),
      now: Date(timeIntervalSince1970: 30)
    )

    // when
    let userItems = try store.list(kind: .user, limit: 10)
    let allItems = try store.list(kind: nil, limit: 10)

    // then
    #expect(userItems.map(\.text) == ["user newer", "user older"])
    #expect(allItems.count == 3)
    #expect(allItems.first?.text == "user newer")
  }

  @Test func fetchRankedOrdersByImportanceThenRecency() throws {
    // given
    let (store, queue) = try freshStore()
    try insertItem(queue, text: "low old", importance: 0, sensitivity: "normal", at: 10)
    try insertItem(queue, text: "high old", importance: 2, sensitivity: "normal", at: 20)
    try insertItem(queue, text: "high new", importance: 2, sensitivity: "normal", at: 40)
    try insertItem(queue, text: "normal new", importance: 1, sensitivity: "normal", at: 50)

    // when
    let ranked = try store.fetchRanked(excludeSensitive: false, limit: 10)

    // then - importance DESC, then created_at DESC.
    #expect(ranked.map(\.text) == ["high new", "high old", "normal new", "low old"])
  }

  @Test func fetchRankedExcludesHighSensitivityWhenAsked() throws {
    // given - the dormant taint guard (③): a tainted turn must not auto-inject high-sensitivity.
    let (store, queue) = try freshStore()
    try insertItem(queue, text: "normal fact", importance: 2, sensitivity: "normal", at: 10)
    try insertItem(queue, text: "secret fact", importance: 2, sensitivity: "high", at: 20)

    // when
    let guarded = try store.fetchRanked(excludeSensitive: true, limit: 10)
    let unguarded = try store.fetchRanked(excludeSensitive: false, limit: 10)

    // then
    #expect(guarded.map(\.text) == ["normal fact"])
    #expect(Set(unguarded.map(\.text)) == ["normal fact", "secret fact"])
  }

  @Test func sqliteFailureSurfacesAsStoreErrorNotRawDatabaseError() throws {
    // given - a session_id with no matching session violates the FK (foreign keys are enabled).
    let (store, _) = try freshStore()

    // when / then
    #expect(throws: StoreError.self) {
      try store.append(
        NewMemoryItem(text: "orphan", kind: .user, sessionId: 9_999),
        now: Date(timeIntervalSince1970: 1)
      )
    }
  }

  @Test func decodeFailsClosedOnUnrecognizedEnumValue() throws {
    // given - a corrupted sensitivity value must not silently decode to a permissive default.
    let (store, queue) = try freshStore()
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO memory_items(text, kind, sensitivity, importance, source, session_id, created_at)
          VALUES ('corrupt', 'user', 'bogus', 1, 'owner', NULL, ?)
          """,
        arguments: [Date(timeIntervalSince1970: 1)]
      )
    }

    // when / then - excludeSensitive:false selects the row so decode runs and fails closed.
    #expect(throws: StoreError.self) {
      _ = try store.fetchRanked(excludeSensitive: false, limit: 10)
    }
  }

  /// Inserts a row directly so a test can set `importance`/`sensitivity` independent of the
  /// `NewMemoryItem` defaults.
  private func insertItem(
    _ queue: DatabaseQueue,
    text: String,
    importance: Int,
    sensitivity: String,
    at seconds: TimeInterval
  ) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO memory_items(text, kind, sensitivity, importance, source, session_id, created_at)
          VALUES (?, 'user', ?, ?, 'owner', NULL, ?)
          """,
        arguments: [text, sensitivity, importance, Date(timeIntervalSince1970: seconds)]
      )
    }
  }
}
