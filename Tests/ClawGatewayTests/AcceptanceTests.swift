import ClawCore
import ClawData
import Foundation
import Logging
import Testing

@testable import ClawGateway

@Suite struct AcceptanceTests {
  // Survives restart: the offset persists and a redelivered update is deduped.
  @Test func offsetPersistsAndDedupsAcrossRestart() async throws {
    // given
    let path = NSTemporaryDirectory() + "claw-accept-\(UInt64.random(in: 0..<(.max))).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }

    // when — first "run": process update 100, advance the cursor
    do {
      let stores = try ClawDatabase.openStores(path: path)
      try stores.allowlist.seedAllowlist(userIds: [42])
      #expect(try stores.processed.claimUpdate(updateId: 100))  // newly claimed
      try stores.cursor.advanceCursor(to: 100)
    }

    // then — "restart": fresh stores on the same file
    let reopened = try ClawDatabase.openStores(path: path)
    #expect(try reopened.cursor.loadCursor() == 100)  // offset survived
    #expect(try reopened.processed.claimUpdate(updateId: 100) == false)  // redelivery deduped
  }
}
