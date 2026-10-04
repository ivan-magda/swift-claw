import ClawCore
import Testing

@testable import ClawTelegram

@Suite
struct TelegramActionEmojiTests {
  @Test
  func disabledEmojisKeepStatusWithoutDecoratingProgress() throws {
    // given
    let emoji = TelegramActionEmoji.answer
    let answer = "Answer \(emoji.fallback)"
    let snapshot = TurnProgressSnapshot(
      phase: .answer,
      elapsedSeconds: 12,
      explanation: nil,
      steps: [],
      olderSteps: TurnToolCounts(succeeded: 0, failed: 0, denied: 0, cancelled: 0),
      answerPreview: answer,
      showsProgress: true
    )

    // when
    let renderer = TelegramProgressRenderer(actionEmojisEnabled: false)
    let draft = try #require(renderer.renderDraft(snapshot))

    // then
    #expect(draft.markdown.hasPrefix("<tg-thinking>\(emoji.statusLabel) · "))
    #expect(draft.markdown.hasSuffix("\n\n" + answer))
    #expect(draft.fallbackMarkdown == nil)
  }

  @Test(arguments: [
    (TurnToolAction.tool, TelegramActionEmoji.working),
    (.search, .search),
    (.readPage, .readPage),
    (.readFile, .readFile),
    (.writeFile, .writeFile),
    (.memory, .memory),
    (.loadSkill, .loadSkill),
    (.executeCode, .executeCode),
    (.coding, .coding),
  ])
  func activeToolCategorySelectsHeadingDespiteLaterCompletedStep(
    action: TurnToolAction,
    emoji: TelegramActionEmoji
  ) throws {
    // given
    let active = step("active", action: action, state: .executing)
    let completed = step("completed", action: .coding, state: .succeeded)

    // when
    let markup = try render(phase: .tool, steps: [active, completed])

    // then
    let opening = "<tg-thinking><tg-emoji emoji-id=\"\(emoji.rawValue)\">"
    #expect(markup.hasPrefix("\(opening)\(emoji.fallback)</tg-emoji> \(emoji.statusLabel) · "))
  }

  @Test(arguments: [
    (TurnProgressPhase.preparing, TelegramActionEmoji.working, "Preparing"),
    (.resumed, .working, "Resuming work"),
    (.model, .thinking, TelegramActionEmoji.thinking.statusLabel),
    (.approval, .approval, TelegramActionEmoji.approval.statusLabel),
    (.answer, .answer, TelegramActionEmoji.answer.statusLabel),
  ])
  func phaseOverridesToolHistory(
    phase: TurnProgressPhase,
    emoji: TelegramActionEmoji,
    label: String
  ) throws {
    // given
    let pending = step("pending", action: .search, state: .pending)

    // when
    let markup = try render(phase: phase, steps: [pending])

    // then
    #expect(markup.hasPrefix("<tg-thinking>\(emoji.markup) \(label) · "))
  }

  @Test
  func pendingToolSelectsItsActionHeading() throws {
    // given
    let pending = step("pending", action: .search, state: .pending)
    let emoji = TelegramActionEmoji.search

    // when
    let markup = try render(phase: .tool, steps: [pending])

    // then
    #expect(markup.hasPrefix("<tg-thinking>\(emoji.markup) \(emoji.statusLabel) · "))
  }

  @Test(arguments: [ToolProgressState.succeeded, .failed, .denied, .cancelled])
  func finishedToolUsesNeutralHeading(state: ToolProgressState) throws {
    // given
    let finished = step("done", action: .search, state: state)
    let emoji = TelegramActionEmoji.working

    // when
    let markup = try render(phase: .tool, steps: [finished])

    // then
    #expect(markup.hasPrefix("<tg-thinking>\(emoji.markup) \(emoji.statusLabel) · "))
  }

  @Test(arguments: [(0, false), (TelegramActionEmoji.answer.fallback.count + 1, true)])
  func tightBudgetsPreferOrdinaryEmojiThenTextWithoutTakingAnswerSpace(
    emojiCharacters: Int,
    keepsEmoji: Bool
  ) throws {
    // given
    let emoji = TelegramActionEmoji.answer
    let full = try render(phase: .answer)
    try #require(full.contains(emoji.markup))
    let textCount = full.count - emoji.markup.count - 1
    let budget = textCount + emojiCharacters
    let answer = String(
      repeating: "a",
      count: TelegramMessageLimits.maxRichMessageCharacters - budget - 2
    )

    // when
    let markup = try render(phase: .answer, answer: answer)

    // then
    #expect(markup.count == TelegramMessageLimits.maxRichMessageCharacters)
    #expect(markup.hasSuffix("</tg-thinking>\n\n\(answer)"))
    #expect(markup.contains("<tg-emoji") == false)
    #expect(markup.contains(emoji.fallback) == keepsEmoji)
  }
}

// MARK: - Fixtures

private extension TelegramActionEmojiTests {
  func step(_ id: String, action: TurnToolAction, state: ToolProgressState) -> TurnToolStep {
    TurnToolStep(
      id: TurnToolStepID(providerCallID: "round", toolCallID: id),
      label: "Read a file",
      preview: "web_search",
      state: state,
      action: action
    )
  }

  func render(
    phase: TurnProgressPhase,
    steps: [TurnToolStep] = [],
    answer: String = ""
  ) throws -> String {
    try #require(
      TelegramProgressRenderer(actionEmojisEnabled: true).render(
        TurnProgressSnapshot(
          phase: phase,
          elapsedSeconds: 12,
          explanation: nil,
          steps: steps,
          olderSteps: TurnToolCounts(succeeded: 0, failed: 0, denied: 0, cancelled: 0),
          answerPreview: answer,
          showsProgress: true
        )
      )
    )
  }
}
