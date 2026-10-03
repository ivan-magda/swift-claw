import ClawCore

/// Draft-only markup. Permanent answers use the existing delivery path directly.
public struct TelegramProgressRenderer: TurnProgressRendering {
  public init() {}

  public func render(_ snapshot: TurnProgressSnapshot) -> String? {
    renderDraft(snapshot)?.markdown
  }

  public func renderDraft(_ snapshot: TurnProgressSnapshot) -> RichDraft? {
    let answer = String(
      snapshot.answerPreview.prefix(TelegramMessageLimits.maxRichMessageCharacters)
    )

    guard snapshot.showsProgress else {
      return answer.isEmpty ? nil : RichDraft(markdown: answer)
    }

    let separator = answer.isEmpty ? "" : "\n\n"
    let budget = min(
      TurnProgressLimits.markupCharacters,
      TelegramMessageLimits.maxRichMessageCharacters - answer.count - separator.count
    )

    let progress = progressMarkup(snapshot, budget: budget)
    if progress.isEmpty {
      return answer.isEmpty ? nil : RichDraft(markdown: answer)
    }

    let markdown = "\(progress)\(separator)\(answer)"
    let fallbackProgress = TelegramActionEmoji.replacingHeading(in: progress)
    let fallbackMarkdown =
      fallbackProgress == progress ? nil : "\(fallbackProgress)\(separator)\(answer)"

    return RichDraft(markdown: markdown, fallbackMarkdown: fallbackMarkdown)
  }
}

// MARK: - Complete Progress Markup

private extension TelegramProgressRenderer {
  static let thinkingOpen = "<tg-thinking>"
  static let thinkingClose = "</tg-thinking>"

  func progressMarkup(_ snapshot: TurnProgressSnapshot, budget: Int) -> String {
    let collapsed = !snapshot.answerPreview.isEmpty
    let emoji = TelegramActionEmoji(snapshot: snapshot)
    let status = collapsed ? emoji.statusLabel : phaseLabel(snapshot.phase, action: emoji)
    let stepCount = totalOlder(snapshot.olderSteps) + snapshot.steps.count
    var heading = "\(status) · \(max(0, snapshot.elapsedSeconds))s"

    if collapsed && stepCount > 0 {
      heading += " · \(stepCount) steps"
    }

    let thinkingTagCharacters = Self.thinkingOpen.count + Self.thinkingClose.count
    guard budget >= thinkingTagCharacters + heading.count else {
      return ""
    }

    let headingBudget = budget - thinkingTagCharacters
    let customEmojiHeading = "\(emoji.markup) \(heading)"
    let fallbackEmojiHeading = "\(emoji.fallback) \(heading)"

    if customEmojiHeading.count <= headingBudget {
      heading = customEmojiHeading
    } else if fallbackEmojiHeading.count <= headingBudget {
      heading = fallbackEmojiHeading
    }

    var thinking = heading
    if !collapsed, let explanation = snapshot.explanation {
      let explanationPreview = ProgressText.preview(
        explanation,
        secretValues: [],
        limit: TurnProgressLimits.explanationCharacters
      )

      let escapedExplanation = explanationMarkup(
        explanationPreview,
        budget: budget - thinkingTagCharacters - heading.count - 3
      )
      if !escapedExplanation.isEmpty {
        thinking += " — " + escapedExplanation
      }
    }

    var markup = Self.thinkingOpen + thinking + Self.thinkingClose
    guard !collapsed else {
      return markup
    }

    let visibleSteps = Array(snapshot.steps.suffix(TurnProgressLimits.visibleToolSteps))
    let olderStepCount = totalOlder(snapshot.olderSteps) + snapshot.steps.count - visibleSteps.count
    let earlierStepsMarkup =
      olderStepCount > 0
      ? "\n\n\(Self.thinkingOpen)\(olderStepCount) earlier steps\(Self.thinkingClose)"
      : ""
    let rowCharacters = budget - markup.count - earlierStepsMarkup.count

    if rowCharacters > 0, !visibleSteps.isEmpty {
      let rowBudget = rowCharacters / visibleSteps.count
      for step in visibleSteps {
        markup += toolRow(step, budget: rowBudget)
      }
    }

    if markup.count + earlierStepsMarkup.count <= budget {
      markup += earlierStepsMarkup
    }

    return markup
  }

  func toolRow(_ step: TurnToolStep, budget: Int) -> String {
    let status = stateLabel(step.state)
    let suffix = " · " + status + Self.thinkingClose
    // Thinking rows update immediately instead of entering the client's answer-text animation.
    let prefix = "\n\n" + Self.thinkingOpen + "• "
    let textBudget = budget - prefix.count - suffix.count

    guard textBudget > 0 else {
      return ""
    }

    let label = ProgressText.preview(
      step.label,
      secretValues: [],
      limit: TurnProgressLimits.previewCharacters
    )
    let preview = step.preview.map {
      ProgressText.preview($0, secretValues: [], limit: TurnProgressLimits.previewCharacters)
    }
    let text =
      if let preview {
        "\(label): \(preview)"
      } else {
        label
      }

    return prefix + escapeHTML(text, budget: textBudget) + suffix
  }

  /// Markdown is literal inside thinking blocks. Convert a provider's outer bold heading to
  /// owned HTML, including when its closing delimiter has not arrived or was preview-truncated.
  func explanationMarkup(_ text: String, budget: Int) -> String {
    guard text.hasPrefix("**") else {
      return escapeHTML(text, budget: budget)
    }

    var body = String(text.dropFirst(2))
    if body.hasSuffix("**") {
      body = String(body.dropLast(2))
    }
    let opening = "<b>"
    let closing = "</b>"
    let escaped = escapeHTML(
      body,
      budget: budget - opening.count - closing.count
    )
    return escaped.isEmpty ? "" : opening + escaped + closing
  }

  func escapeHTML(_ text: String, budget: Int) -> String {
    var result = ""

    for character in text {
      let token: String
      switch character {
      case "&":
        token = "&amp;"
      case "<":
        token = "&lt;"
      case ">":
        token = "&gt;"
      default:
        token = String(character)
      }

      guard result.count + token.count <= budget else {
        break
      }

      result += token
    }

    return result
  }

  func phaseLabel(_ phase: TurnProgressPhase, action: TelegramActionEmoji) -> String {
    switch phase {
    case .preparing:
      "Preparing"
    case .resumed:
      "Resuming work"
    case .model, .tool, .approval, .answer:
      action.statusLabel
    }
  }

  func stateLabel(_ state: ToolProgressState) -> String {
    switch state {
    case .pending:
      "Pending"
    case .awaitingApproval:
      "Waiting for approval"
    case .executing:
      "Executing"
    case .succeeded:
      "Succeeded"
    case .failed:
      "Failed"
    case .denied:
      "Denied"
    case .cancelled:
      "Cancelled"
    }
  }

  func totalOlder(_ counts: TurnToolCounts) -> Int {
    counts.succeeded + counts.failed + counts.denied + counts.cancelled
  }
}
