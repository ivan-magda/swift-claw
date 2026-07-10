public protocol AllowlistStore: Sendable {
  func seedAllowlist(userIds: [Int64]) throws(StoreError)
  func allowlistContains(userId: Int64) throws(StoreError) -> Bool
  func allowlistCount() throws(StoreError) -> Int
}

public protocol ProcessedUpdateStore: Sendable {
  /// INSERT OR IGNORE → true if newly claimed, false if already seen.
  /// Synchronous: no await may span the check, so the dedup claim can't interleave.
  func claimUpdate(updateId: Int64) throws(StoreError) -> Bool
}

public protocol UpdateCursorStore: Sendable {
  func loadCursor() throws(StoreError) -> Int64?
  func advanceCursor(to updateId: Int64) throws(StoreError)
}
