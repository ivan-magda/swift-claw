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

  @Test func mapsOtherDatabaseErrorsToUnexpected() throws {
    // given
    let constraint = DatabaseError(
      resultCode: .SQLITE_CONSTRAINT,
      message: "UNIQUE constraint failed"
    )

    // when
    let classified = ClawDatabase.classifyError(constraint)

    // then — the contract: no raw DatabaseError leaks past a store. A non-diskFull SQLite code
    // becomes StoreError.unexpected (carrying the original description for logs).
    #expect(classified as? DatabaseError == nil)
    guard case .unexpected = try #require(classified as? StoreError) else {
      Issue.record("expected StoreError.unexpected, got \(classified)")
      return
    }

    // and the write seam surfaces a domain StoreError, never a raw DatabaseError
    let writer = try ClawDatabase.makeInMemoryQueue()
    #expect(throws: StoreError.self) {
      try writer.writeMapping { (_: Database) in throw constraint }
    }
  }

  @Test func passesNonDatabaseErrorsThroughUnchanged() throws {
    // given — an already-domain error must pass through, never be re-wrapped
    let domain = StoreError.unexpected("already typed")

    // when
    let classified = ClawDatabase.classifyError(domain)

    // then
    #expect(classified as? StoreError == .unexpected("already typed"))
  }
}
