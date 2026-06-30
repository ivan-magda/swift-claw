import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite struct MemoryRankerTests {
  @Test func ranksByImportanceThenRecency() throws {
    // given
    let olderHigh = try memory(id: 1, text: "older high", importance: .high, dayOffset: -2)
    let newerNormal = try memory(id: 2, text: "newer normal", importance: .normal, dayOffset: 0)
    let newerHigh = try memory(id: 3, text: "newer high", importance: .high, dayOffset: -1)

    // when
    let ranked = MemoryRanker.rank(
      items: [newerNormal, olderHigh, newerHigh],
      excludeSensitive: false,
      cap: 1_000
    )

    // then
    #expect(ranked.map(\.id) == [3, 1, 2])
  }

  @Test func breaksExactTiesByNewestDatabaseId() throws {
    // given
    let first = try memory(id: 1, text: "first", importance: .normal, dayOffset: 0)
    let second = try memory(id: 2, text: "second", importance: .normal, dayOffset: 0)
    let third = try memory(id: 3, text: "third", importance: .normal, dayOffset: 0)

    // when
    let ranked = MemoryRanker.rank(items: [first, third, second], excludeSensitive: false, cap: 1_000)

    // then
    #expect(ranked.map(\.id) == [3, 2, 1])
  }

  @Test func fillsCapAtItemBoundariesWithoutMidFactTruncation() throws {
    // given
    let first = try memory(id: 1, text: "alpha", importance: .high, dayOffset: 0)
    let second = try memory(id: 2, text: "bravo", importance: .normal, dayOffset: 0)
    let third = try memory(id: 3, text: "charlie", importance: .low, dayOffset: 0)

    // when
    let ranked = MemoryRanker.rank(items: [third, second, first], excludeSensitive: false, cap: 11)

    // then
    #expect(ranked.map(\.text) == ["alpha", "bravo"])
  }

  @Test func skipsOversizedHigherRankedItemAndKeepsSmallerFittingItem() throws {
    // given
    let oversized = try memory(
      id: 1,
      text: "this fact does not fit",
      importance: .high,
      dayOffset: 0
    )
    let fitting = try memory(id: 2, text: "fits", importance: .normal, dayOffset: 0)

    // when
    let ranked = MemoryRanker.rank(items: [oversized, fitting], excludeSensitive: false, cap: 4)

    // then
    #expect(ranked.map(\.id) == [2])
  }

  @Test func excludesHighSensitivityWhenRequested() throws {
    // given
    let normal = try memory(
      id: 1,
      text: "normal",
      sensitivity: .normal,
      importance: .normal,
      dayOffset: 0
    )
    let high = try memory(
      id: 2,
      text: "secret",
      sensitivity: .high,
      importance: .high,
      dayOffset: 0
    )

    // when
    let ranked = MemoryRanker.rank(items: [high, normal], excludeSensitive: true, cap: 1_000)

    // then
    #expect(ranked.map(\.id) == [1])
  }
}

private func memory(
  id: Int64,
  text: String,
  sensitivity: Sensitivity = .normal,
  importance: Importance,
  dayOffset: Int
) throws -> MemoryItem {
  let createdAt = try #require(
    Calendar(identifier: .gregorian).date(
      byAdding: .day,
      value: dayOffset,
      to: Date(timeIntervalSince1970: 1_800_000_000)
    )
  )

  return MemoryItem(
    id: id,
    text: text,
    kind: .project,
    sensitivity: sensitivity,
    importance: importance,
    source: .owner,
    sessionId: 42,
    createdAt: createdAt
  )
}
