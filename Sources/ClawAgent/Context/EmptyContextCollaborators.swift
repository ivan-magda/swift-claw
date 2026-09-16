import ClawCore

package struct EmptyMemoryStore: MemoryStore {
  package init() {}

  package func list(kind: MemoryKind?, limit: Int) throws(StoreError) -> [MemoryItem] {
    []
  }

  package func get(id: Int64) throws(StoreError) -> MemoryItem? {
    nil
  }

  package func fetchRanked(excludeSensitive: Bool, limit: Int) throws(StoreError) -> [MemoryItem] {
    []
  }
}

package struct EmptyRetriever: Retriever {
  package init() {}

  package func searchRelevantMessages(
    query: String,
    currentSessionID: Int64,
    restrictToSessionID: Int64?,
    windowStartMessageID: Int64?,
    excludedMessageIDs: [Int64],
    limit: Int
  ) throws(StoreError) -> [RecallHit] {
    []
  }
}
