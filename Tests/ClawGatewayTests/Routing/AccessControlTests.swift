import ClawCore
import Testing

@testable import ClawGateway

private struct StubAllowlist: AllowlistStore {
  let allowed: Set<Int64>

  func seedAllowlist(userIds: [Int64]) throws(StoreError) {}

  func allowlistContains(userId: Int64) throws(StoreError) -> Bool { allowed.contains(userId) }

  func allowlistCount() throws(StoreError) -> Int { allowed.count }
}

private struct ThrowingAllowlist: AllowlistStore {
  func seedAllowlist(userIds: [Int64]) throws(StoreError) { throw StoreError.unexpected("boom") }

  func allowlistContains(userId: Int64) throws(StoreError) -> Bool {
    throw StoreError.unexpected("boom")
  }

  func allowlistCount() throws(StoreError) -> Int { throw StoreError.unexpected("boom") }
}

@Suite struct AccessControlTests {
  @Test(
    "allowlist membership",
    arguments: [
      (userId: Int64(42), expected: true),
      (userId: Int64(7), expected: false),
    ]
  )
  func allowlistMembership(userId: Int64, expected: Bool) {
    // given
    let access = AccessControl(allowlist: StubAllowlist(allowed: [42]))

    // then
    #expect(access.isAllowed(userId: userId) == expected)
  }

  @Test func storeErrorFailsClosed() {
    // given
    let access = AccessControl(allowlist: ThrowingAllowlist())

    // then
    #expect(access.isAllowed(userId: 42) == false)
  }
}
