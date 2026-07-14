import Testing

@testable import ClawGateway

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
