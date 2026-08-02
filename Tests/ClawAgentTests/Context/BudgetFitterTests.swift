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

  @Test func historyFitStopsAtFirstNonFittingMessageToPreserveContiguousWindow() throws {
    // given
    let section = FittableSection(
      id: .history,
      tier: .mixed,
      priority: ContextPriority(70),
      truncatable: true,
      cap: 10,
      units: [
        SectionUnit(id: "history-2", content: "newest", canTruncate: false),
        SectionUnit(id: "history-1", content: "oversized middle", canTruncate: false),
        SectionUnit(id: "history-0", content: "o", canTruncate: false),
      ]
    )
    let budget = ContextBudget(
      inputCapGraphemes: 10,
      userFileCap: 1,
      memoryFileCap: 1,
      itemsCap: 1,
      historyCap: 10,
      recallCap: 1,
      skillsCap: 1,
      recallHitCap: 1
    )

    // when
    let fitted = try BudgetFitter.fitWithUnits([section], budget: budget)

    // then
    let history = try #require(fitted.first { row in row.id == .history })
    #expect(history.units.map(\.id) == ["history-2"])
    #expect(history.content == "newest")
  }

  @Test func existingFitStillReturnsSectionsWithSameContent() throws {
    // given
    let section = FittableSection(
      id: .memoryItems,
      tier: .untrustedLabeled,
      priority: ContextPriority(60),
      truncatable: true,
      cap: 20,
      units: [
        SectionUnit(id: "memory-1", content: "alpha", canTruncate: false),
        SectionUnit(id: "memory-2", content: "bravo", canTruncate: false),
      ]
    )
    let budget = ContextBudget(
      inputCapGraphemes: 20,
      userFileCap: 1,
      memoryFileCap: 1,
      itemsCap: 20,
      historyCap: 1,
      recallCap: 1,
      skillsCap: 1,
      recallHitCap: 1
    )

    // when
    let sections = try BudgetFitter.fit([section], budget: budget)

    // then
    #expect(
      sections == [
        Section(
          id: .memoryItems,
          tier: .untrustedLabeled,
          priority: ContextPriority(60),
          truncatable: true,
          cap: 20,
          content: "alpha\nbravo"
        )
      ]
    )
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

  @Test func skillsRowKeepsAPrefixAndMarksTheDroppedSkills() throws {
    // given
    let section = skillsSection(
      cap: 800,
      units: [
        ("skill-alpha", 700),
        ("skill-bravo", 300),
        ("skill-charlie", 60),
        ("skill-delta", 50),
      ]
    )
    let budget = testBudget(inputCap: 2_000)

    // when
    let fitted = try BudgetFitter.fitWithUnits([section], budget: budget)

    // then
    let skills = try #require(fitted.first { row in row.id == .skills })
    #expect(skills.units.map(\.id) == ["skill-alpha", BudgetFitter.dropMarkerUnitID])
    #expect(skills.units.last?.content == "(showing 1 of 4 skills)")
    #expect(skills.droppedUnitIDs == ["skill-bravo", "skill-charlie", "skill-delta"])
    #expect(skills.content.count <= 800)
  }

  @Test func skillsRowCarriesNoMarkerWhenEverySkillFits() throws {
    // given
    let section = skillsSection(cap: 800, units: [("skill-alpha", 100), ("skill-bravo", 200)])
    let budget = testBudget(inputCap: 2_000)

    // when
    let fitted = try BudgetFitter.fitWithUnits([section], budget: budget)

    // then
    let skills = try #require(fitted.first { row in row.id == .skills })
    #expect(skills.units.map(\.id) == ["skill-alpha", "skill-bravo"])
    #expect(skills.droppedUnitIDs.isEmpty)
    #expect(skills.content.contains("showing") == false)
  }

  @Test func skillsRowShipsUnmarkedWhenTheMarkerCannotFitBesideTheKeptSkill() throws {
    // given — a cap that admits the first index line but not that line plus the marker
    let section = skillsSection(cap: 30, units: [("skill-alpha", 20), ("skill-bravo", 40)])
    let budget = testBudget(inputCap: 2_000)

    // when
    let fitted = try BudgetFitter.fitWithUnits([section], budget: budget)

    // then — the skill the owner can still use outranks the annotation about the one they cannot
    let skills = try #require(fitted.first { row in row.id == .skills })
    #expect(skills.units.map(\.id) == ["skill-alpha"])
    #expect(skills.content.contains("showing") == false)
    #expect(skills.droppedUnitIDs == ["skill-bravo"])
  }

  @Test func squeezedSkillsRowRemarksTheSkillsItStillShows() throws {
    // given — capped rows overshoot the residual, so the lowest-priority row is re-fit smaller
    let sections = [
      nonTruncatable(id: .policy, priority: 0, content: filler("p", 100)),
      truncatable(id: .history, priority: 70, cap: 200, units: [filler("h", 200)]),
      skillsSection(
        cap: 200,
        units: [("skill-alpha", 40), ("skill-bravo", 40), ("skill-charlie", 40)]
      ),
    ]
    let budget = testBudget(inputCap: 380)

    // when
    let fitted = try BudgetFitter.fitWithUnits(sections, budget: budget)

    // then — the marker counts what survived the re-fit, not what the first pass kept
    let skills = try #require(fitted.first { row in row.id == .skills })
    #expect(skills.units.map(\.id) == ["skill-alpha", BudgetFitter.dropMarkerUnitID])
    #expect(skills.units.last?.content == "(showing 1 of 3 skills)")
    #expect(skills.content.count <= 80)
  }

  @Test func memoryItemsRowKeepsTheGreedySubsetAcrossANonFittingUnit() throws {
    // given — rank-ordered memory selection is not the skills index: a big item is skipped, not a
    // stop signal
    let section = FittableSection(
      id: .memoryItems,
      tier: .untrustedLabeled,
      priority: ContextPriority(60),
      truncatable: true,
      cap: 800,
      units: [
        SectionUnit(id: "memory-1", content: filler("a", 700), canTruncate: false),
        SectionUnit(id: "memory-2", content: filler("b", 300), canTruncate: false),
        SectionUnit(id: "memory-3", content: filler("c", 60), canTruncate: false),
      ]
    )
    let budget = testBudget(inputCap: 2_000)

    // when
    let fitted = try BudgetFitter.fitWithUnits([section], budget: budget)

    // then
    let items = try #require(fitted.first { row in row.id == .memoryItems })
    #expect(items.units.map(\.id) == ["memory-1", "memory-3"])
    #expect(items.droppedUnitIDs == ["memory-2"])
    #expect(items.content.contains("showing") == false)
  }

  @Test func historyNewestUnitSurvivesWhenItAloneExceedsBudget() throws {
    // given
    let section = FittableSection(
      id: .history,
      tier: .mixed,
      priority: ContextPriority(70),
      truncatable: true,
      cap: 4,
      units: [
        SectionUnit(id: "history-1", content: "answer this please", canTruncate: false),
        SectionUnit(id: "history-0", content: "older", canTruncate: false),
      ]
    )
    let budget = ContextBudget(
      inputCapGraphemes: 5,
      userFileCap: 1,
      memoryFileCap: 1,
      itemsCap: 1,
      historyCap: 4,
      recallCap: 1,
      skillsCap: 1,
      recallHitCap: 1
    )

    // when
    let fitted = try BudgetFitter.fitWithUnits([section], budget: budget)

    // then
    let history = try #require(fitted.first { row in row.id == .history })
    #expect(history.units.map(\.id) == ["history-1"])
    #expect(history.content == "answer this please")
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

private func filler(_ character: Character, _ count: Int) -> String {
  String(repeating: character, count: count)
}

private func skillsSection(cap: Int, units: [(id: String, count: Int)]) -> FittableSection {
  FittableSection(
    id: .skills,
    tier: .untrustedLabeled,
    priority: ContextPriority(90),
    truncatable: true,
    cap: cap,
    dropMarker: .showingCount(noun: "skills"),
    units: units.map { unit in
      SectionUnit(id: unit.id, content: filler("s", unit.count), canTruncate: false)
    }
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
