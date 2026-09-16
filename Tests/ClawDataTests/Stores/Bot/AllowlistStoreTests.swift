import ClawCore
import ClawTestSupport
import GRDB
import Testing

@testable import ClawData

@Suite
struct AllowlistStoreTests {
  private func freshStore() throws -> AllowlistStoreGRDB {
    let queue = try TestDatabase.make()
    return AllowlistStoreGRDB(writer: queue)
  }

  @Test
  func seededUserIsContained() throws {
    // given
    let store = try freshStore()

    // when
    try store.seedAllowlist(userIDs: [42, 99])

    // then
    #expect(try store.allowlistContains(userID: 42))
    #expect(try store.allowlistContains(userID: 99))
  }

  @Test
  func unknownUserIsNotContained() throws {
    // given
    let store = try freshStore()
    try store.seedAllowlist(userIDs: [42])

    // then
    #expect(try store.allowlistContains(userID: 7) == false)
  }

  @Test
  func seedingIsIdempotent() throws {
    // given
    let store = try freshStore()

    // when
    try store.seedAllowlist(userIDs: [42])
    try store.seedAllowlist(userIDs: [42, 99])

    // then
    #expect(try store.allowlistCount() == 2)
  }

  @Test
  func emptyStoreCountIsZero() throws {
    // given
    let store = try freshStore()

    // then
    #expect(try store.allowlistCount() == 0)
  }
}
