import ClawCore
import Testing

@testable import ClawGateway

private struct StubAllowlist: AllowlistStore {
  let allowed: Set<Int64>

  func seedAllowlist(userIds: [Int64]) throws {}

  func allowlistContains(userId: Int64) throws -> Bool { allowed.contains(userId) }

  func allowlistCount() throws -> Int { allowed.count }
}

private struct ThrowingAllowlist: AllowlistStore {
  struct Boom: Error {}

  func seedAllowlist(userIds: [Int64]) throws { throw Boom() }

  func allowlistContains(userId: Int64) throws -> Bool { throw Boom() }

  func allowlistCount() throws -> Int { throw Boom() }
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
