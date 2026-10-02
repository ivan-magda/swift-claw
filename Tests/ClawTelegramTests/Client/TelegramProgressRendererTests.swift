import ClawCore
import ClawTelegram
import Foundation
import Testing

@Suite
struct TelegramProgressRendererTests {
  @Test
  func expandedRowsCollapseWhenAnswerArrives() throws {
    // given
    let renderer = TelegramProgressRenderer()
    let steps = (0..<TurnProgressLimits.visibleToolSteps + 2).map { index in
      TurnToolStep(
        id: TurnToolStepID(providerCallID: "round", toolCallID: "\(index)"),
        label: "Search \(index)",
        preview: "query",
        state: .succeeded
      )
    }

    // when
    let working = try #require(renderer.render(snapshot(steps: steps)))
    let answer = "**Answer** [source](https://example.org)\n\n<blockquote>quoted</blockquote>"
    let streaming = try #require(renderer.render(snapshot(steps: steps, answer: answer)))

    // then
    #expect(
      working.components(separatedBy: "<tg-thinking>• ").count - 1
        == TurnProgressLimits.visibleToolSteps
    )
    #expect(working.contains("2 earlier"))
    #expect(working.contains("Search 0") == false)
    #expect(working.contains("<tg-thinking>2 earlier steps</tg-thinking>"))
    for block in working.components(separatedBy: "\n\n") {
      #expect(block.hasPrefix("<tg-thinking>"))
      #expect(block.hasSuffix("</tg-thinking>"))
    }
    #expect(streaming.components(separatedBy: "<tg-thinking>").count - 1 == 1)
    #expect(streaming.contains("Progress"))
    #expect(streaming.hasSuffix(answer))
    #expect(streaming.contains("</tg-thinking>"))
  }

  @Test
  func explanationConvertsOuterBoldToHTMLWhileRowsEscapeHTMLAndControls() throws {
    // given
    let renderer = TelegramProgressRenderer()
    let text = "< & [link](https://example.org)\u{001B} 👩🏽‍💻"
    let step = TurnToolStep(
      id: TurnToolStepID(providerCallID: "r", toolCallID: "t"),
      label: "Read",
      preview: text,
      state: .executing
    )

    // when
    let markup = try #require(
      renderer.render(snapshot(explanation: "**" + text + "**", steps: [step]))
    )
    let thinking = try #require(markup.components(separatedBy: "</tg-thinking>").first)

    // then
    #expect(thinking.contains("&lt; &amp; [link](https://example.org)"))
    #expect(thinking.contains("<b>&lt; &amp;"))
    #expect(thinking.hasSuffix("</b>"))
    #expect(thinking.contains("**") == false)
    #expect(markup.contains("<tg-thinking>• Read: &lt; &amp; [link](https://example.org)"))
    #expect(markup.contains("\u{001B}") == false)
    #expect(markup.contains("👩🏽‍💻"))
  }

  @Test
  func incompleteExplanationHeadingClosesItsHTMLBold() throws {
    // given
    let renderer = TelegramProgressRenderer()

    // when
    let markup = try #require(renderer.render(snapshot(explanation: "**Fetching sequentially")))

    // then
    #expect(markup.contains("<b>Fetching sequentially</b>"))
    #expect(markup.contains("**") == false)
  }

  @Test
  func escapedExpansionStaysBoundedAndTagsRemainComplete() throws {
    // given
    let renderer = TelegramProgressRenderer()
    let hostile = String(repeating: "&", count: TurnProgressLimits.previewCharacters)
    let steps = (0..<TurnProgressLimits.visibleToolSteps).map { index in
      TurnToolStep(
        id: TurnToolStepID(providerCallID: "r", toolCallID: "\(index)"),
        label: hostile,
        preview: hostile,
        state: .awaitingApproval
      )
    }

    // when
    let markup = try #require(
      renderer.render(
        snapshot(
          explanation: "**"
            + String(
              repeating: "&",
              count: TurnProgressLimits.explanationCharacters
            ) + "**",
          steps: steps
        )
      )
    )

    // then
    #expect(markup.count <= TurnProgressLimits.markupCharacters)
    #expect(markup.hasPrefix("<tg-thinking>"))
    #expect(markup.contains("</tg-thinking>"))
    #expect(markup.contains("</b></tg-thinking>"))
    #expect(markup.components(separatedBy: "<tg-thinking>• ").count - 1 == steps.count)
    #expect(markup.contains("&amp;"))
    for block in markup.components(separatedBy: "\n\n") {
      #expect(block.hasSuffix("</tg-thinking>"))
      #expect(block.contains("&amp;"))
    }
  }

  @Test
  func answerKeepsItsBudgetAndDisabledProgressIsAbsent() throws {
    // given
    let renderer = TelegramProgressRenderer()
    let answer = String(repeating: "界", count: TelegramMessageLimits.maxRichMessageCharacters)

    // when
    let full = try #require(renderer.render(snapshot(answer: answer)))
    let disabled = try #require(renderer.render(snapshot(answer: "answer", showsProgress: false)))
    let waiting = renderer.render(snapshot(showsProgress: false))

    // then
    #expect(full == answer)
    #expect(full.count == TelegramMessageLimits.maxRichMessageCharacters)
    #expect(disabled == "answer")
    #expect(waiting == nil)
  }
}

// MARK: - Fixtures

private extension TelegramProgressRendererTests {
  func snapshot(
    explanation: String? = nil,
    steps: [TurnToolStep] = [],
    answer: String = "",
    showsProgress: Bool = true
  ) -> TurnProgressSnapshot {
    TurnProgressSnapshot(
      phase: answer.isEmpty ? .model : .answer,
      elapsedSeconds: 12,
      explanation: explanation,
      steps: steps,
      olderSteps: TurnToolCounts(succeeded: 0, failed: 0, denied: 0, cancelled: 0),
      answerPreview: answer,
      showsProgress: showsProgress
    )
  }
}
