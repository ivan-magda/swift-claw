import ClawCore
import GRDB
import Testing

@testable import ClawData

@Suite struct DiskFullMappingTests {
  @Test func mapsSqliteFullToStoreErrorDiskFull() throws {
    // given
    let sqliteFull = DatabaseError(resultCode: .SQLITE_FULL, message: "database or disk is full")

    // when
    let classified = ClawDatabase.classifyError(sqliteFull)

    // then
    #expect(classified as? StoreError == .diskFull)

    // and the write seam surfaces the same typed error when a write throws SQLITE_FULL
    let writer = try ClawDatabase.makeInMemoryQueue()
    #expect(throws: StoreError.diskFull) {
      try writer.writeMapping { (_: Database) in throw sqliteFull }
    }
  }

  @Test func passesOtherErrorsThrough() throws {
    // given
    let constraint = DatabaseError(
      resultCode: .SQLITE_CONSTRAINT,
      message: "UNIQUE constraint failed"
    )

    // when
    let classified = ClawDatabase.classifyError(constraint)

    // then — unchanged: a non-diskFull DatabaseError is never re-typed to StoreError
    #expect(classified as? StoreError == nil)
    #expect((classified as? DatabaseError)?.resultCode.primaryResultCode == .SQLITE_CONSTRAINT)
  }
}
