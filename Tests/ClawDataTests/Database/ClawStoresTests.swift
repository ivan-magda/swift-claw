import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawData

@Suite
struct ClawStoresTests {
  @Test
  func openStoresMigratesAndReturnsWorkingStores() throws {
    // given
    let path = makeTempDatabasePath(prefix: "claw-stores")
    defer { try? FileManager.default.removeItem(atPath: path) }

    // when
    let stores = try ClawDatabase.openStores(path: path)

    // then
    try stores.allowlist.seedAllowlist(userIDs: [42])
    #expect(try stores.allowlist.allowlistContains(userID: 42))
    #expect(try stores.processed.claimUpdate(updateID: 1))
    try stores.cursor.advanceCursor(to: 5)
    #expect(try stores.cursor.loadCursor() == 5)
  }

  // Survives restart: the offset persists and a redelivered update is deduped.
  @Test
  func openStoresKeepsTheOffsetAndDedupesAcrossReopen() throws {
    // given
    let path = makeTempDatabasePath(prefix: "claw-stores-reopen")
    defer { try? FileManager.default.removeItem(atPath: path) }

    // when — first "run": process update 100, advance the cursor
    do {
      let stores = try ClawDatabase.openStores(path: path)
      #expect(try stores.processed.claimUpdate(updateID: 100))  // newly claimed
      try stores.cursor.advanceCursor(to: 100)
    }

    // then — "restart": fresh stores on the same file
    let reopened = try ClawDatabase.openStores(path: path)
    #expect(try reopened.cursor.loadCursor() == 100)  // offset survived
    #expect(try reopened.processed.claimUpdate(updateID: 100) == false)  // redelivery deduped
  }

  @Test
  func openStoresExposesMemoryStoresAndRetriever() throws {
    // given - a real temp-file pool, exercising the production composition path.
    let path = makeTempDatabasePath(prefix: "claw-stores-mem")
    defer { try? FileManager.default.removeItem(atPath: path) }
    let stores = try ClawDatabase.openStores(path: path)
    let now = Date(timeIntervalSince1970: 100)

    // when - the confirmed-write seam, the read seam, and the retriever are all reachable.
    let remembered = try stores.memoryCommands.applyRemember(
      updateID: 1,
      item: NewMemoryItem(text: "swift recall fact", kind: .project, sessionID: nil),
      now: now
    )
    let listed = try stores.memory.list(kind: .project, limit: 10)
    let recall = try stores.retriever.searchRelevantMessages(
      query: "swift",
      currentSessionID: 1,
      restrictToSessionID: nil,
      windowStartMessageID: nil,
      excludedMessageIDs: [],
      limit: 5
    )

    // then
    let stored = try #require(remembered.item)
    #expect(listed.map(\.id) == [stored.id])
    #expect(try stores.memory.get(id: stored.id)?.text == "swift recall fact")
    #expect(recall.isEmpty)  // no messages persisted, so the corpus is empty
  }
}
