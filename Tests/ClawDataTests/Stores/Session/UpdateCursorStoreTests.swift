import ClawTestSupport
import Testing

@testable import ClawData

@Suite
struct UpdateCursorStoreTests {
  private func freshStore() throws -> UpdateCursorStoreGRDB {
    let queue = try TestDatabase.make()
    return UpdateCursorStoreGRDB(writer: queue)
  }

  @Test
  func cursorStartsNil() throws {
    // given
    let store = try freshStore()

    // then
    #expect(try store.loadCursor() == nil)
  }

  @Test
  func cursorIsMonotonic() throws {
    // given
    let store = try freshStore()

    // when
    try store.advanceCursor(to: 100)
    try store.advanceCursor(to: 50)

    // then
    #expect(try store.loadCursor() == 100)
  }
}
