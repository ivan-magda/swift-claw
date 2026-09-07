import ClawCore
import Foundation
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
    #expect(classified == .diskFull)

    // and the write seam surfaces the same typed error when a write throws SQLITE_FULL
    let database = MappedDatabase(writer: try ClawDatabase.makeInMemoryQueue())
    #expect(throws: StoreError.diskFull) {
      try database.writeMapping { (_: Database) in throw sqliteFull }
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

    // then — the contract: no raw DatabaseError leaks past a store (the `StoreError` return type
    // now holds it at compile time). A non-diskFull SQLite code becomes StoreError.unexpected
    // (carrying the original description for logs).
    guard case .unexpected = classified else {
      Issue.record("expected StoreError.unexpected, got \(classified)")
      return
    }

    // and the write seam surfaces a domain StoreError, never a raw DatabaseError
    let database = MappedDatabase(writer: try ClawDatabase.makeInMemoryQueue())
    #expect(throws: StoreError.self) {
      try database.writeMapping { (_: Database) in throw constraint }
    }
  }

  @Test func mappedDatabaseTranslatesFailuresOnBothSeams() throws {
    // given
    let sqliteFull = DatabaseError(resultCode: .SQLITE_FULL, message: "database or disk is full")
    let database = MappedDatabase(writer: try ClawDatabase.makeInMemoryQueue())

    // when / then — the write seam surfaces the domain error
    #expect(throws: StoreError.diskFull) {
      try database.writeMapping { (_: Database) in throw sqliteFull }
    }

    // and the read seam classifies identically
    #expect(throws: StoreError.diskFull) {
      try database.readMapping { (_: Database) in throw sqliteFull }
    }
  }

  @Test func passesStoreErrorsThroughUnchanged() throws {
    // given — an already-domain error must pass through, never be re-wrapped
    let domain = StoreError.unexpected("already typed")

    // when
    let classified = ClawDatabase.classifyError(domain)

    // then
    #expect(classified == .unexpected("already typed"))
  }
}

// MARK: - Coder Writer

extension DiskFullMappingTests {
  @Test func coderWriterMapsDiskFull() throws {
    // given
    let fixture = try CoderStoreFixture()
    let id = try fixture.admittedID()
    let result = CoderResult(
      state: .succeeded,
      summary: String(repeating: "x", count: 1_000_000),
      workspacePath: nil,
      startingCommit: nil,
      baselineObserved: false,
      changedFiles: nil,
      branch: nil,
      commit: nil,
      publication: .absent,
      reportedChecks: [],
      reportedUsage: nil,
      commitAuthor: nil,
      githubActor: nil,
      failure: nil
    )
    try fixture.queue.writeWithoutTransaction { db in
      let pages = try #require(try Int.fetchOne(db, sql: "PRAGMA page_count"))
      try db.execute(sql: "PRAGMA max_page_count = \(pages)")
    }
    // when
    #expect(throws: StoreError.diskFull) {
      try fixture.store.complete(
        id: id,
        expectedState: .admitted,
        result: result,
        chunks: [],
        releaseReservation: true,
        now: fixture.now
      )
    }
    // then
    #expect(try fixture.store.job(id: id)?.state == .admitted)
  }
}
