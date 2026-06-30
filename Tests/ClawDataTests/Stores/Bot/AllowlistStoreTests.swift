import ClawCore
import GRDB
import Testing

@testable import ClawData

@Suite struct AllowlistStoreTests {
  private func freshStore() throws -> AllowlistStoreGRDB {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return AllowlistStoreGRDB(writer: queue)
  }

  @Test func seededUserIsContained() throws {
    // given
    let store = try freshStore()

    // when
    try store.seedAllowlist(userIds: [42, 99])

    // then
    #expect(try store.allowlistContains(userId: 42))
    #expect(try store.allowlistContains(userId: 99))
  }

  @Test func unknownUserIsNotContained() throws {
    // given
    let store = try freshStore()
    try store.seedAllowlist(userIds: [42])

    // then
    #expect(try store.allowlistContains(userId: 7) == false)
  }

  @Test func seedingIsIdempotent() throws {
    // given
    let store = try freshStore()

    // when
    try store.seedAllowlist(userIds: [42])
    try store.seedAllowlist(userIds: [42, 99])

    // then
    #expect(try store.allowlistCount() == 2)
  }

  @Test func emptyStoreCountIsZero() throws {
    // given
    let store = try freshStore()

    // then
    #expect(try store.allowlistCount() == 0)
  }
}
