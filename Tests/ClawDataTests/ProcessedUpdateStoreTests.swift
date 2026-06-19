import ClawCore
import Testing

@testable import ClawData

@Suite struct ProcessedUpdateStoreTests {
  private func freshStore() throws -> ProcessedUpdateStoreGRDB {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return ProcessedUpdateStoreGRDB(writer: queue)
  }

  @Test func firstClaimSucceeds() throws {
    // given
    let store = try freshStore()

    // then
    #expect(try store.claimUpdate(updateId: 100))
  }

  @Test func secondClaimOfSameUpdateIsRejected() throws {
    // given
    let store = try freshStore()

    // when
    let first = try store.claimUpdate(updateId: 100)

    // then
    #expect(first)
    #expect(try store.claimUpdate(updateId: 100) == false)
  }

  @Test func distinctUpdatesAreEachClaimed() throws {
    // given
    let store = try freshStore()

    // then
    #expect(try store.claimUpdate(updateId: 1))
    #expect(try store.claimUpdate(updateId: 2))
  }
}
