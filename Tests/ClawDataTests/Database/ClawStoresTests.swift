import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawData

@Suite struct ClawStoresTests {
  @Test func openStoresMigratesAndReturnsWorkingStores() throws {
    // given
    let path = makeTempDatabasePath(prefix: "claw-stores")
    defer { try? FileManager.default.removeItem(atPath: path) }

    // when
    let stores = try ClawDatabase.openStores(path: path)

    // then
    try stores.allowlist.seedAllowlist(userIds: [42])
    #expect(try stores.allowlist.allowlistContains(userId: 42))
    #expect(try stores.processed.claimUpdate(updateId: 1))
    try stores.cursor.advanceCursor(to: 5)
    #expect(try stores.cursor.loadCursor() == 5)
  }

  @Test func openStoresExposesMemoryStoresAndRetriever() throws {
    // given - a real temp-file pool, exercising the production composition path.
    let path = makeTempDatabasePath(prefix: "claw-stores-mem")
    defer { try? FileManager.default.removeItem(atPath: path) }
    let stores = try ClawDatabase.openStores(path: path)
    let now = Date(timeIntervalSince1970: 100)

    // when - the confirmed-write seam, the read seam, and the retriever are all reachable.
    let remembered = try stores.memoryCommands.applyRemember(
      updateId: 1,
      item: NewMemoryItem(text: "swift recall fact", kind: .project, sessionId: nil),
      now: now
    )
    let listed = try stores.memory.list(kind: .project, limit: 10)
    let recall = try stores.retriever.searchRelevantMessages(
      query: "swift",
      currentSessionId: 1,
      windowStartMessageId: nil,
      excludedMessageIds: [],
      limit: 5
    )

    // then
    let stored = try #require(remembered.item)
    #expect(listed.map(\.id) == [stored.id])
    #expect(try stores.memory.get(id: stored.id)?.text == "swift recall fact")
    #expect(recall.isEmpty)  // no messages persisted, so the corpus is empty
  }
}
