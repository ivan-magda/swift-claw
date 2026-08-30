import ClawCore
import Foundation

package struct EmptyMemoryStore: MemoryStore {
  package init() {}

  package func append(
    _ newItem: NewMemoryItem,
    now: Date
  ) throws(StoreError) -> MemoryItem {
    throw StoreError.unexpected("empty memory store does not accept appends")
  }

  package func list(kind: MemoryKind?, limit: Int) throws(StoreError) -> [MemoryItem] { [] }

  package func get(id: Int64) throws(StoreError) -> MemoryItem? { nil }

  package func delete(id: Int64) throws(StoreError) -> Bool { false }

  package func fetchRanked(
    excludeSensitive: Bool,
    limit: Int
  ) throws(StoreError) -> [MemoryItem] { [] }
}

package struct EmptyRetriever: Retriever {
  package init() {}

  package func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    restrictToSessionId: Int64?,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    limit: Int
  ) throws(StoreError) -> [RecallHit] { [] }
}
