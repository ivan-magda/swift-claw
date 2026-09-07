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

  /// `ContextBuilder.spec(for:)` traps on a row id with no spec, so a new case added without its
  /// entry is a crash the compiler cannot see. This closes that for every future case as well.
  @Test func everyRowIDHasExactlyOneSpec() {
    // given
    let ids = ContextRowID.allCases

    // when
    let specs = ids.map { id in
      ContextRowPolicy.specs.filter { spec in
        spec.id == id
      }
    }

    // then
    #expect(
      specs.allSatisfy { matches in
        matches.count == 1
      }
    )
  }

  @Test func theLessonsRowIsFencedAsUntrustedAndNeverTruncated() throws {
    // given
    let lessons = try #require(
      ContextRowPolicy.specs.first { spec in
        spec.id == .lessons
      }
    )

    // when / then — lessons are advisory data a model wrote, so they can never ride the system tier
    #expect(lessons.tier == .untrustedLabeled)
    #expect(lessons.truncatable == false)
    #expect(ContextRowID.lessons.resolve(in: .default, residualGraphemes: 10) == nil)
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
    #expect(ContextRowID.policy.resolve(in: budget, residualGraphemes: nil) == nil)
    #expect(ContextRowID.userFile.resolve(in: budget, residualGraphemes: nil) == 11)
    #expect(ContextRowID.memoryFile.resolve(in: budget, residualGraphemes: nil) == 22)
    #expect(ContextRowID.memoryItems.resolve(in: budget, residualGraphemes: nil) == 33)
    #expect(ContextRowID.history.resolve(in: budget, residualGraphemes: nil) == 44)
    #expect(ContextRowID.recall.resolve(in: budget, residualGraphemes: nil) == 55)
    #expect(ContextRowID.skills.resolve(in: budget, residualGraphemes: nil) == 66)
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
    #expect(ContextRowID.policy.resolve(in: budget, residualGraphemes: 50) == nil)
    #expect(ContextRowID.userFile.resolve(in: budget, residualGraphemes: 50) == 11)
    #expect(ContextRowID.memoryFile.resolve(in: budget, residualGraphemes: 50) == 22)
    #expect(ContextRowID.memoryItems.resolve(in: budget, residualGraphemes: 50) == 7)
    #expect(ContextRowID.history.resolve(in: budget, residualGraphemes: 50) == 30)
    #expect(ContextRowID.recall.resolve(in: budget, residualGraphemes: 50) == 10)
    #expect(ContextRowID.skills.resolve(in: budget, residualGraphemes: 50) == 2)
  }
}
