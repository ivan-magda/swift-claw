public protocol AllowlistStore: Sendable {
  func seedAllowlist(userIDs: [Int64]) throws(StoreError)

  func allowlistContains(userID: Int64) throws(StoreError) -> Bool

  func allowlistCount() throws(StoreError) -> Int
}

public protocol ProcessedUpdateStore: Sendable {
  /// Returns whether this update was newly claimed rather than already seen.
  ///
  /// The deduplication claim is synchronous: no suspension may split the check from the write.
  func claimUpdate(updateID: Int64) throws(StoreError) -> Bool
}

public protocol UpdateCursorStore: Sendable {
  /// Returns the last confirmed update ID, or nil before any cursor has been stored.
  ///
  /// The next polling offset is one greater than this value.
  ///
  /// - Throws: A `StoreError` if the cursor cannot be read.
  func loadCursor() throws(StoreError) -> Int64?

  /// Records a confirmed update ID without moving an existing cursor backward.
  ///
  /// Advance only after routing has safely completed; any required inbound write must commit first.
  ///
  /// - Throws: A `StoreError` if the cursor cannot be persisted.
  func advanceCursor(to updateID: Int64) throws(StoreError)
}
