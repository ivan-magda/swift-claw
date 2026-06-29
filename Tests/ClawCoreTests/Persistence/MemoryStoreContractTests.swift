import Foundation
import Testing

@testable import ClawCore

@Suite struct MemoryStoreContractTests {
  private struct MemoryStoreSpy: MemoryStore {
    func append(_ newItem: NewMemoryItem, now: Date) throws -> MemoryItem {
      MemoryItem(
        id: 1,
        text: newItem.text,
        kind: newItem.kind,
        sensitivity: newItem.sensitivity,
        importance: newItem.importance,
        source: newItem.source,
        sessionId: newItem.sessionId,
        createdAt: now
      )
    }

    func list(kind: MemoryKind?, limit: Int) throws -> [MemoryItem] { [] }
    func get(id: Int64) throws -> MemoryItem? { nil }
    func delete(id: Int64) throws -> Bool { false }
    func fetchRanked(excludeSensitive: Bool, limit: Int) throws -> [MemoryItem] { [] }
  }

  private struct MemoryCommandStoreSpy: MemoryCommandStore {
    func applyRemember(
      updateId: Int64,
      item: NewMemoryItem,
      now: Date
    ) throws -> MemoryCommandResult {
      MemoryCommandResult(
        newlyClaimed: true,
        item: MemoryItem(
          id: 9,
          text: item.text,
          kind: item.kind,
          sensitivity: item.sensitivity,
          importance: item.importance,
          source: item.source,
          sessionId: item.sessionId,
          createdAt: now
        )
      )
    }

    func applyForget(updateId: Int64, itemId: Int64, now: Date) throws -> MemoryCommandResult {
      MemoryCommandResult(newlyClaimed: true, item: nil)
    }
  }

  private struct RetrieverSpy: Retriever {
    func searchRelevantMessages(
      query: String,
      currentSessionId: Int64,
      windowStartMessageId: Int64?,
      excludedMessageIds: [Int64],
      limit: Int
    ) throws -> [RecallHit] {
      [
        RecallHit(
          id: 4,
          sessionId: 1,
          role: .user,
          content: query,
          score: RecallScore(value: 10),
          createdAt: Date(timeIntervalSince1970: 50)
        )
      ]
    }
  }

  @Test func memoryStoreProtocolCanAppendAndFetchRankedItems() throws {
    // given
    let store = MemoryStoreSpy()
    let now = Date(timeIntervalSince1970: 100)
    let newItem = NewMemoryItem(text: "ship 3a", kind: .project, sessionId: 2)

    // when
    let item = try store.append(newItem, now: now)
    let ranked = try store.fetchRanked(excludeSensitive: true, limit: 5)

    // then
    #expect(item.text == "ship 3a")
    #expect(ranked.isEmpty)
  }

  @Test func memoryCommandResultCarriesDedupOutcomeAndOptionalItem() throws {
    // given
    let store = MemoryCommandStoreSpy()
    let newItem = NewMemoryItem(text: "owner fact", kind: .user, sessionId: nil)

    // when
    let remembered = try store.applyRemember(
      updateId: 10,
      item: newItem,
      now: Date(timeIntervalSince1970: 1)
    )
    let forgotten = try store.applyForget(
      updateId: 11,
      itemId: 9,
      now: Date(timeIntervalSince1970: 2)
    )

    // then
    #expect(remembered.newlyClaimed)
    #expect(remembered.item?.text == "owner fact")
    #expect(forgotten.newlyClaimed)
    #expect(forgotten.item == nil)
  }

  @Test func retrieverProtocolReturnsRecallHits() throws {
    // given
    let retriever = RetrieverSpy()

    // when
    let hits = try retriever.searchRelevantMessages(
      query: "ship",
      currentSessionId: 3,
      windowStartMessageId: 20,
      excludedMessageIds: [20, 21],
      limit: 5
    )

    // then
    #expect(hits.map(\.content) == ["ship"])
  }
}
