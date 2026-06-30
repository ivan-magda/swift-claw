import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite struct ContextRowPolicyTests {
  @Test func rowPolicyMirrorsArchitectureSectionNinePointTwo() {
    // given / when
    let specs = ContextRowPolicy.specs

    // then
    #expect(
      specs == [
        RowSpec(
          id: .policy,
          tier: .system,
          priority: ContextPriority(0),
          truncatable: false,
          cap: .none
        ),
        RowSpec(
          id: .systemWorkspace,
          tier: .system,
          priority: ContextPriority(10),
          truncatable: false,
          cap: .none
        ),
        RowSpec(
          id: .tools,
          tier: .system,
          priority: ContextPriority(20),
          truncatable: false,
          cap: .none
        ),
        RowSpec(
          id: .metadata,
          tier: .system,
          priority: ContextPriority(30),
          truncatable: false,
          cap: .none
        ),
        RowSpec(
          id: .userFile,
          tier: .untrustedLabeled,
          priority: ContextPriority(40),
          truncatable: false,
          cap: .userFile
        ),
        RowSpec(
          id: .memoryFile,
          tier: .untrustedLabeled,
          priority: ContextPriority(50),
          truncatable: false,
          cap: .memoryFile
        ),
        RowSpec(
          id: .memoryItems,
          tier: .untrustedLabeled,
          priority: ContextPriority(60),
          truncatable: true,
          cap: .memoryItems
        ),
        RowSpec(
          id: .history,
          tier: .mixed,
          priority: ContextPriority(70),
          truncatable: true,
          cap: .history
        ),
        RowSpec(
          id: .recall,
          tier: .untrustedLabeled,
          priority: ContextPriority(80),
          truncatable: true,
          cap: .recall
        ),
        RowSpec(
          id: .skills,
          tier: .untrustedLabeled,
          priority: ContextPriority(90),
          truncatable: true,
          cap: .skills
        ),
      ]
    )
  }

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
