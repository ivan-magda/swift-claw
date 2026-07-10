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
  func append(_ newItem: NewMemoryItem, now: Date) throws -> MemoryItem
  func list(kind: MemoryKind?, limit: Int) throws -> [MemoryItem]
  func get(id: Int64) throws -> MemoryItem?
  func delete(id: Int64) throws -> Bool
  func fetchRanked(excludeSensitive: Bool, limit: Int) throws -> [MemoryItem]
}

public protocol MemoryCommandStore: Sendable {
  /// Atomic confirmed remember: claim update + insert memory item + audit in one write.
  func applyRemember(
    updateId: Int64,
    item: NewMemoryItem,
    now: Date
  ) throws -> MemoryCommandResult
  /// Atomic confirmed delete: claim update + hard-delete memory item + audit in one write.
  func applyForget(updateId: Int64, itemId: Int64, now: Date) throws
    -> MemoryCommandResult
}

public protocol Retriever: Sendable {
  func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    limit: Int
  ) throws -> [RecallHit]
}
