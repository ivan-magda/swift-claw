import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite struct BudgetFitterTests {
  @Test func keepsNonTruncatableRowsEvenWhenResidualIsSmall() throws {
    // given
    let sections = [
      nonTruncatable(id: .policy, priority: 0, content: "policy"),
      truncatable(id: .skills, priority: 90, cap: 20, units: ["alpha", "bravo"]),
    ]
    let budget = testBudget(inputCap: 7)

    // when
    let fitted = try BudgetFitter.fit(sections, budget: budget)

    // then
    #expect(fitted.map(\.id) == [.policy])
    #expect(fitted.first?.content == "policy")
  }

  @Test func throwsWhenNonTruncatableRowsAloneExceedInputCap() {
    // given
    let sections = [
      nonTruncatable(id: .policy, priority: 0, content: "policy"),
      nonTruncatable(id: .metadata, priority: 30, content: "today"),
    ]
    let budget = testBudget(inputCap: 5)

    // when / then
    #expect(throws: BudgetFitterError.nonTruncatableRowsExceedInputCap(required: 11, cap: 5)) {
      try BudgetFitter.fit(sections, budget: budget)
    }
  }

  @Test func honorsPerRowCapsBeforeUsingResidualBudget() throws {
    // given
    let sections = [
      nonTruncatable(id: .policy, priority: 0, content: "P"),
      truncatable(id: .memoryItems, priority: 60, cap: 6, units: ["aaa", "bbb", "ccc"]),
      truncatable(id: .history, priority: 70, cap: 10, units: ["dddd", "eeee"]),
    ]
    let budget = testBudget(inputCap: 50)

    // when
    let fitted = try BudgetFitter.fit(sections, budget: budget)

    // then
    #expect(fitted.map(\.id) == [.policy, .memoryItems, .history])
    #expect(fitted.first { section in section.id == .memoryItems }?.content == "aaa")
    #expect(fitted.first { section in section.id == .history }?.content == "dddd\neeee")
  }

  @Test func cutsLowestPriorityRowsFirstWhenCappedRowsExceedResidual() throws {
    // given
    let sections = [
      nonTruncatable(id: .policy, priority: 0, content: "P"),
      truncatable(id: .memoryItems, priority: 60, cap: 20, units: ["item1", "item2"]),
      truncatable(id: .history, priority: 70, cap: 20, units: ["hist1", "hist2"]),
      truncatable(id: .recall, priority: 80, cap: 20, units: ["rec1", "rec2"]),
      truncatable(id: .skills, priority: 90, cap: 20, units: ["skill1", "skill2"]),
    ]
    let budget = testBudget(inputCap: 32)

    // when
    let fitted = try BudgetFitter.fit(sections, budget: budget)

    // then
    #expect(fitted.map(\.id) == [.policy, .memoryItems, .history, .recall])
    #expect(fitted.first { section in section.id == .memoryItems }?.content == "item1\nitem2")
    #expect(fitted.first { section in section.id == .history }?.content == "hist1\nhist2")
    #expect(fitted.first { section in section.id == .recall }?.content == "rec1\nrec2")
    #expect(fitted.contains { section in section.id == .skills } == false)
  }

  @Test func residualScaledCapsPreserveLowerPrioritySlicesOnSmallBudgets() throws {
    // given
    let budget = sliceBudget(inputCap: 20)
    let residual = budget.inputCapGraphemes
    let sections = [
      truncatable(
        id: .memoryItems,
        priority: 60,
        cap: try #require(
          ContextRowCap.memoryItems.resolve(in: budget, residualGraphemes: residual)
        ),
        units: ["aaa", "bbb", "ccc", "ddd", "eee"]
      ),
      truncatable(
        id: .history,
        priority: 70,
        cap: try #require(ContextRowCap.history.resolve(in: budget, residualGraphemes: residual)),
        units: ["hhhh", "iiii"]
      ),
      truncatable(
        id: .recall,
        priority: 80,
        cap: try #require(ContextRowCap.recall.resolve(in: budget, residualGraphemes: residual)),
        units: ["rrrr"]
      ),
      truncatable(
        id: .skills,
        priority: 90,
        cap: try #require(ContextRowCap.skills.resolve(in: budget, residualGraphemes: residual)),
        units: ["s"]
      ),
    ]

    // when
    let fitted = try BudgetFitter.fit(sections, budget: budget)

    // then
    #expect(fitted.map(\.id) == [.memoryItems, .history, .recall, .skills])
    #expect(fitted.first { section in section.id == .memoryItems }?.content == "aaa")
    #expect(fitted.first { section in section.id == .history }?.content == "hhhh\niiii")
    #expect(fitted.first { section in section.id == .recall }?.content == "rrrr")
    #expect(fitted.first { section in section.id == .skills }?.content == "s")
  }

  @Test func dropsWholeUnitsWhenUnitCannotBeTruncated() throws {
    // given
    let sections = [
      truncatable(
        id: .memoryItems,
        priority: 60,
        cap: 9,
        units: ["small", "too-large"],
        canTruncate: false
      )
    ]
    let budget = testBudget(inputCap: 9)

    // when
    let fitted = try BudgetFitter.fit(sections, budget: budget)

    // then
    #expect(fitted.map(\.id) == [.memoryItems])
    #expect(fitted.first?.content == "small")
  }

  @Test func truncatesUnitWithMarkerWhenUnitAllowsCharacterTruncation() throws {
    // given
    let sections = [
      FittableSection(
        id: .recall,
        tier: .untrustedLabeled,
        priority: ContextPriority(80),
        truncatable: true,
        cap: 13,
        units: [SectionUnit(content: "abcdefghijklmnopqrstuvwxyz", canTruncate: true)]
      )
    ]
    let budget = testBudget(inputCap: 13)

    // when
    let fitted = try BudgetFitter.fit(sections, budget: budget)

    // then
    #expect(fitted.first?.content == "a…[truncated]")
    #expect(fitted.first?.content.count == 13)
  }
}

private func testBudget(inputCap: Int) -> ContextBudget {
  ContextBudget(
    inputCapGraphemes: inputCap,
    userFileCap: 1_375,
    memoryFileCap: 2_200,
    itemsCap: 1_500,
    historyCap: 6_000,
    recallCap: 2_000,
    skillsCap: 800,
    recallHitCap: 400
  )
}

private func sliceBudget(inputCap: Int) -> ContextBudget {
  ContextBudget(
    inputCapGraphemes: inputCap,
    userFileCap: 11,
    memoryFileCap: 22,
    itemsCap: 15,
    historyCap: 60,
    recallCap: 20,
    skillsCap: 5,
    recallHitCap: 4
  )
}

private func nonTruncatable(
  id: ContextRowID,
  priority: Int,
  content: String
) -> FittableSection {
  FittableSection(
    id: id,
    tier: .system,
    priority: ContextPriority(priority),
    truncatable: false,
    cap: nil,
    units: [SectionUnit(content: content, canTruncate: false)]
  )
}

private func truncatable(
  id: ContextRowID,
  priority: Int,
  cap: Int,
  units: [String],
  canTruncate: Bool = false
) -> FittableSection {
  FittableSection(
    id: id,
    tier: id == .history ? .mixed : .untrustedLabeled,
    priority: ContextPriority(priority),
    truncatable: true,
    cap: cap,
    units: units.map { content in SectionUnit(content: content, canTruncate: canTruncate) }
  )
}
