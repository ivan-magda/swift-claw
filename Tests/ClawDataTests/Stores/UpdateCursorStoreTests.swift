import Foundation
import Testing

@testable import ClawCore
@testable import ClawData

@Suite struct UpdateCursorStoreTests {
  private func freshStore() throws -> UpdateCursorStoreGRDB {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return UpdateCursorStoreGRDB(writer: queue)
  }

  @Test func cursorStartsNil() throws {
    // given
    let store = try freshStore()

    // then
    #expect(try store.loadCursor() == nil)
  }

  @Test func advanceThenLoad() throws {
    // given
    let store = try freshStore()

    // when
    try store.advanceCursor(to: 100)

    // then
    #expect(try store.loadCursor() == 100)
  }

  @Test func cursorIsMonotonic() throws {
    // given
    let store = try freshStore()

    // when
    try store.advanceCursor(to: 100)
    try store.advanceCursor(to: 50)

    // then
    #expect(try store.loadCursor() == 100)
  }

  @Test func cursorSurvivesReopen() throws {
    // given: persist on one connection, read on a fresh one (stand-in for SIGTERM + restart)
    let path = NSTemporaryDirectory() + "claw-cursor-\(UInt64.random(in: 0..<(.max))).sqlite"
    defer {
      try? FileManager.default.removeItem(atPath: path)
    }

    do {
      let pool = try ClawDatabase.makePool(path: path)
      try ClawDatabase.migrate(pool)
      try UpdateCursorStoreGRDB(writer: pool).advanceCursor(to: 777)
    }

    // when
    let reopened = try ClawDatabase.makePool(path: path)
    try ClawDatabase.migrate(reopened)

    // then
    #expect(try UpdateCursorStoreGRDB(writer: reopened).loadCursor() == 777)
  }
}
