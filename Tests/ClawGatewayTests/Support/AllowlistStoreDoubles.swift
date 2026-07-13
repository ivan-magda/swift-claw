import ClawCore

/// In-memory allowlist double: membership and count come from a fixed owner set; seeding is a no-op.
struct StubAllowlist: AllowlistStore {
  let allowed: Set<Int64>

  func seedAllowlist(userIds: [Int64]) throws(StoreError) {}

  func allowlistContains(userId: Int64) throws(StoreError) -> Bool { allowed.contains(userId) }

  func allowlistCount() throws(StoreError) -> Int { allowed.count }
}

/// Allowlist double whose every operation throws, to exercise fail-closed and seed-failure paths.
struct ThrowingAllowlist: AllowlistStore {
  func seedAllowlist(userIds: [Int64]) throws(StoreError) { throw StoreError.unexpected("boom") }

  func allowlistContains(userId: Int64) throws(StoreError) -> Bool {
    throw StoreError.unexpected("boom")
  }

  func allowlistCount() throws(StoreError) -> Int { throw StoreError.unexpected("boom") }
}
