import Foundation

public struct MemoryCommandResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let item: MemoryItem?

  public init(newlyClaimed: Bool, item: MemoryItem?) {
    self.newlyClaimed = newlyClaimed
    self.item = item
  }
}

public protocol MemoryStore: Sendable {
  func append(_ newItem: NewMemoryItem, now: Date) throws(StoreError) -> MemoryItem
  func list(kind: MemoryKind?, limit: Int) throws(StoreError) -> [MemoryItem]
  func get(id: Int64) throws(StoreError) -> MemoryItem?
  func delete(id: Int64) throws(StoreError) -> Bool
  func fetchRanked(excludeSensitive: Bool, limit: Int) throws(StoreError) -> [MemoryItem]
}

public protocol MemoryCommandStore: Sendable {
  /// Atomic confirmed remember: claim update + insert memory item + audit in one write.
  func applyRemember(
    updateId: Int64,
    item: NewMemoryItem,
    now: Date
  ) throws(StoreError) -> MemoryCommandResult
  /// Atomic confirmed delete: claim update + hard-delete memory item + audit in one write.
  func applyForget(
    updateId: Int64,
    itemId: Int64,
    now: Date
  ) throws(StoreError) -> MemoryCommandResult
}

public protocol Retriever: Sendable {
  /// `restrictToSessionId` confines the search to one session's own rows. A group topic passes its
  /// own id: every attendee's line is stored trusted, so an unrestricted search would read one
  /// room's words into another room's prompt. `nil` keeps the cross-session reach a DM relies on.
  func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    restrictToSessionId: Int64?,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    limit: Int
  ) throws(StoreError) -> [RecallHit]
}
