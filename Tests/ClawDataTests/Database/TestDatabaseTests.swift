import ClawTestSupport
import GRDB
import Testing

struct TestDatabaseTests {
  @Test func copiesIsolateExistingAndFutureFixtures() throws {
    // given
    let first = try TestDatabase.make()
    let second = try TestDatabase.make()

    // when
    try first.write { db in
      try db.execute(sql: "INSERT INTO allowlist(user_id, added_at) VALUES (7, 0)")
    }
    let third = try TestDatabase.make()

    // then
    let firstCount = try first.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM allowlist")
    }
    #expect(firstCount == 1)
    for queue in [second, third] {
      let count = try queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM allowlist")
      }
      #expect(count == 0)
    }
  }
}
