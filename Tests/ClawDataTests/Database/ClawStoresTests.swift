import ClawTestSupport
import Foundation
import Testing

@testable import ClawData

@Suite
struct ClawStoresTests {
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
}
