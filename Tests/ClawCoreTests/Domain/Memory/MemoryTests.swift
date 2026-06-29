import Foundation
import Testing

@testable import ClawCore

@Suite struct MemoryTests {
  @Test func memoryKindHasStableRawValuesAndListingOrder() {
    // given / when
    let kinds = MemoryKind.allCases

    // then
    #expect(kinds.map(\.rawValue) == ["user", "feedback", "project", "reference"])
  }

  @Test func importanceHasSqlSortableOrdinals() {
    // given / when / then
    #expect(Importance.low.rawValue == 0)
    #expect(Importance.normal.rawValue == 1)
    #expect(Importance.high.rawValue == 2)
    #expect(Importance.high > Importance.normal)
    #expect(Importance.normal > Importance.low)
  }

  @Test func newMemoryItemDefaultsToOwnerNormalMemory() {
    // given
    let item = NewMemoryItem(
      text: "ship increment 3a",
      kind: .project,
      sessionId: 42
    )

    // then
    #expect(item.text == "ship increment 3a")
    #expect(item.kind == .project)
    #expect(item.sensitivity == .normal)
    #expect(item.importance == .normal)
    #expect(item.source == .owner)
    #expect(item.sessionId == 42)
  }

  @Test func newMemoryItemAcceptsFullInitializerOrder() {
    // given
    let item = NewMemoryItem(
      text: "prefer concise replies",
      kind: .feedback,
      sensitivity: .high,
      importance: .low,
      source: .owner,
      sessionId: 99
    )

    // then
    #expect(item.text == "prefer concise replies")
    #expect(item.kind == .feedback)
    #expect(item.sensitivity == .high)
    #expect(item.importance == .low)
    #expect(item.source == .owner)
    #expect(item.sessionId == 99)
  }

  @Test func storedMemoryItemCarriesProvenanceAndDate() {
    // given
    let createdAt = Date(timeIntervalSince1970: 100)

    // when
    let item = MemoryItem(
      id: 7,
      text: "likes terse plans",
      kind: .feedback,
      sensitivity: .normal,
      importance: .high,
      source: .owner,
      sessionId: nil,
      createdAt: createdAt
    )

    // then
    #expect(item.id == 7)
    #expect(item.text == "likes terse plans")
    #expect(item.kind == .feedback)
    #expect(item.sensitivity == .normal)
    #expect(item.importance == .high)
    #expect(item.source == .owner)
    #expect(item.sessionId == nil)
    #expect(item.createdAt == createdAt)
  }
}
