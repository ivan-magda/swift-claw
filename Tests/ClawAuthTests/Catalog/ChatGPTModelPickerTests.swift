import ClawCore
import Testing

@testable import ClawAuth

@Suite struct ChatGPTModelPickerTests {
  private static let catalog = [
    ChatGPTCatalogModel(slug: "gpt-5.4", priority: 1),
    ChatGPTCatalogModel(slug: "gpt-5.4-codex", priority: 2),
    ChatGPTCatalogModel(slug: "gpt-5.4-mini", priority: 3),
  ]

  @Test(arguments: [true, false])
  func theConfiguredModelIsTheDefaultWhenTheCatalogStillOffersIt(isInteractive: Bool) {
    // given / when
    let outcome = ChatGPTModelPicker.select(
      catalog: Self.catalog,
      configuredSuffix: "gpt-5.4-mini",
      isInteractive: isInteractive,
      chosenIndex: nil
    )

    // then
    #expect(
      outcome
        == .chose(ChatGPTModelChoice(slug: "gpt-5.4-mini", origin: .configuredDefault))
    )
  }

  @Test(arguments: [
    String?.none,
    "gpt-4-retired",
    "gpt 5",
    "",
    "-invalid",
  ])
  func theFirstReturnedModelIsTheDefaultWhenNoConfiguredModelApplies(configured: String?) {
    // given / when
    let outcome = ChatGPTModelPicker.select(
      catalog: Self.catalog,
      configuredSuffix: configured,
      isInteractive: true,
      chosenIndex: nil
    )

    // then
    #expect(outcome == .chose(ChatGPTModelChoice(slug: "gpt-5.4", origin: .firstReturnedDefault)))
  }

  @Test(arguments: [1, 2, 3])
  func aNumberedChoiceOnATerminalSelectsThatRow(index: Int) {
    // given / when
    let outcome = ChatGPTModelPicker.select(
      catalog: Self.catalog,
      configuredSuffix: nil,
      isInteractive: true,
      chosenIndex: index
    )

    // then
    #expect(
      outcome == .chose(ChatGPTModelChoice(slug: Self.catalog[index - 1].slug, origin: .owner))
    )
  }

  @Test(arguments: [0, -1, 4, 512, Int.max, Int.min])
  func anIndexOutsideTheNumberedListAsksAgain(index: Int) {
    // given / when
    let outcome = ChatGPTModelPicker.select(
      catalog: Self.catalog,
      configuredSuffix: nil,
      isInteractive: true,
      chosenIndex: index
    )

    // then
    #expect(outcome == .indexOutOfRange)
  }

  /// The rule the non-interactive path exists to keep: with no terminal to prompt, the outcome is
  /// the same default a terminal would have offered, and an index that could only have come from a
  /// prompt that never ran changes nothing.
  @Test(arguments: [Int?.none, 2, 3, 99])
  func aNonInteractiveRunTakesTheDeterministicDefaultWithoutPrompting(index: Int?) {
    // given / when
    let outcome = ChatGPTModelPicker.select(
      catalog: Self.catalog,
      configuredSuffix: nil,
      isInteractive: false,
      chosenIndex: index
    )

    // then
    #expect(outcome == .chose(ChatGPTModelChoice(slug: "gpt-5.4", origin: .firstReturnedDefault)))
  }

  @Test(arguments: [true, false])
  func anEmptyCatalogSelectsNothing(isInteractive: Bool) {
    // given / when
    let outcome = ChatGPTModelPicker.select(
      catalog: [],
      configuredSuffix: "gpt-5.4",
      isInteractive: isInteractive,
      chosenIndex: 1
    )

    // then
    #expect(outcome == .noEligibleModels)
  }

  @Test func aChoiceRendersTheExactQualifiedShellAssignment() {
    // given
    let choice = ChatGPTModelChoice(slug: "gpt-5.4", origin: .owner)

    // when / then
    #expect(choice.assignment == "CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4")
  }
}
