import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite struct ContextRowPolicyTests {
  @Test func rowPolicyPrioritiesAreUniqueAndAlreadySorted() {
    // given
    let specs = ContextRowPolicy.specs

    // when
    let priorities = specs.map(\.priority)
    let sortedPriorities = priorities.sorted()

    // then
    #expect(priorities == sortedPriorities)
    #expect(Set(priorities).count == priorities.count)
  }

  @Test func rowCapsResolveThroughContextBudgetWhenResidualIsAbsent() {
    // given
    let budget = ContextBudget(
      inputCapGraphemes: 100,
      userFileCap: 11,
      memoryFileCap: 22,
      itemsCap: 33,
      historyCap: 44,
      recallCap: 55,
      skillsCap: 66,
      recallHitCap: 77
    )

    // when / then
    #expect(ContextRowCap.none.resolve(in: budget, residualGraphemes: nil) == nil)
    #expect(ContextRowCap.userFile.resolve(in: budget, residualGraphemes: nil) == 11)
    #expect(ContextRowCap.memoryFile.resolve(in: budget, residualGraphemes: nil) == 22)
    #expect(ContextRowCap.memoryItems.resolve(in: budget, residualGraphemes: nil) == 33)
    #expect(ContextRowCap.history.resolve(in: budget, residualGraphemes: nil) == 44)
    #expect(ContextRowCap.recall.resolve(in: budget, residualGraphemes: nil) == 55)
    #expect(ContextRowCap.skills.resolve(in: budget, residualGraphemes: nil) == 66)
  }

  @Test func truncatableRowCapsScaleByResidualBudgetShare() {
    // given
    let budget = ContextBudget(
      inputCapGraphemes: 100,
      userFileCap: 11,
      memoryFileCap: 22,
      itemsCap: 15,
      historyCap: 60,
      recallCap: 20,
      skillsCap: 5,
      recallHitCap: 77
    )

    // when / then
    #expect(ContextRowCap.none.resolve(in: budget, residualGraphemes: 50) == nil)
    #expect(ContextRowCap.userFile.resolve(in: budget, residualGraphemes: 50) == 11)
    #expect(ContextRowCap.memoryFile.resolve(in: budget, residualGraphemes: 50) == 22)
    #expect(ContextRowCap.memoryItems.resolve(in: budget, residualGraphemes: 50) == 7)
    #expect(ContextRowCap.history.resolve(in: budget, residualGraphemes: 50) == 30)
    #expect(ContextRowCap.recall.resolve(in: budget, residualGraphemes: 50) == 10)
    #expect(ContextRowCap.skills.resolve(in: budget, residualGraphemes: 50) == 2)
  }
}
