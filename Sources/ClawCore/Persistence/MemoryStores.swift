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
  /// Lists stored memories, optionally restricted to one kind.
  ///
  /// - Parameters:
  ///   - kind: The kind to include, or nil to include every kind.
  ///   - limit: The requested maximum number of memories.
  /// - Returns: The selected memories, newest first.
  /// - Throws: A `StoreError` if the memories cannot be read or decoded.
  func list(kind: MemoryKind?, limit: Int) throws(StoreError) -> [MemoryItem]

  func get(id: Int64) throws(StoreError) -> MemoryItem?

  /// Selects memories for context by descending importance, then recency.
  ///
  /// - Parameters:
  ///   - excludeSensitive: Whether to exclude high-sensitivity memories from the selection.
  ///   - limit: The requested maximum number of memories before context-budget fitting.
  /// - Returns: The ranked memories, without relevance scoring or grapheme-budget fitting.
  /// - Throws: A `StoreError` if the memories cannot be read or decoded.
  func fetchRanked(excludeSensitive: Bool, limit: Int) throws(StoreError) -> [MemoryItem]
}

public protocol MemoryCommandStore: Sendable {
  /// Atomic confirmed remember: claim update + insert memory item + audit in one write.
  func applyRemember(updateID: Int64, item: NewMemoryItem, now: Date) throws(StoreError)
    -> MemoryCommandResult

  /// Atomic confirmed delete: claim update + hard-delete memory item + audit in one write.
  func applyForget(updateID: Int64, itemID: Int64, now: Date) throws(StoreError)
    -> MemoryCommandResult
}

public protocol Retriever: Sendable {
  /// Recalls trusted user and assistant messages using full-text relevance ranking.
  ///
  /// - Parameters:
  ///   - query: Text to match; a query with no searchable tokens returns no results.
  ///   - currentSessionID: The session whose visible history must not be duplicated in recall.
  ///   - restrictToSessionID: The only session to search, or nil for cross-session recall.
  ///     A group topic supplies its own session ID to prevent cross-topic disclosure.
  ///   - windowStartMessageID: The first visible message ID in `currentSessionID`, or nil when
  ///     there is no visible range to exclude. Messages in that session at or above it are omitted.
  ///   - excludedMessageIDs: Additional message IDs to omit from the results.
  ///   - limit: The requested maximum number of recall hits.
  /// - Returns: Matching messages ordered by BM25 relevance, best first; tool and untrusted rows
  ///   are excluded.
  /// - Throws: A `StoreError` if the message archive cannot be queried or a result cannot be decoded.
  func searchRelevantMessages(
    query: String,
    currentSessionID: Int64,
    restrictToSessionID: Int64?,
    windowStartMessageID: Int64?,
    excludedMessageIDs: [Int64],
    limit: Int
  ) throws(StoreError) -> [RecallHit]
}
