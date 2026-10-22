import Foundation
import Testing

@testable import ClawCore

@Suite
struct MemoryTests {
  @Test
  func memoryKindHasStableRawValuesAndListingOrder() {
    // given / when
    let kinds = MemoryKind.allCases

    // then
    #expect(kinds.map(\.rawValue) == ["user", "feedback", "project", "reference"])
  }

  @Test
  func importanceHasSqlSortableOrdinals() {
    // given / when / then
    #expect(Importance.low.rawValue == 0)
    #expect(Importance.normal.rawValue == 1)
    #expect(Importance.high.rawValue == 2)
    #expect(Importance.high > Importance.normal)
    #expect(Importance.normal > Importance.low)
  }

  @Test
  func newMemoryItemDefaultsToOwnerNormalMemory() {
    // given
    let item = NewMemoryItem(text: "ship increment 3a", kind: .project, sessionID: 42)

    // then
    #expect(item.text == "ship increment 3a")
    #expect(item.kind == .project)
    #expect(item.sensitivity == .normal)
    #expect(item.importance == .normal)
    #expect(item.source == .owner)
    #expect(item.sessionID == 42)
  }
}
