import ClawCore
import Foundation
import Testing

@testable import ClawData

@Suite struct ClawStoresTests {
  @Test func openStoresMigratesAndReturnsWorkingStores() throws {
    // given
    let path = NSTemporaryDirectory() + "claw-stores-\(UInt64.random(in: 0..<(.max))).sqlite"
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
}
