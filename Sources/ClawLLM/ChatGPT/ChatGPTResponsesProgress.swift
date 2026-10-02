import ClawCore
import Foundation

/// Tracks bounded display-only explanations. Original replay material stays in the item accumulator.
struct ChatGPTResponsesProgress: Sendable {
  private let bounds: ChatGPTResponsesBounds
  private let secretValues: [String]
  private let attemptID = UUID().uuidString
  private var items: [ExplanationKey: ExplanationItem] = [:]

  /// Charges original text bytes, even when redaction reduces the displayed text.
  private(set) var retainedTextBytes = 0

  init(bounds: ChatGPTResponsesBounds, secretValues: [String]) {
    self.bounds = bounds
    self.secretValues = secretValues
  }

  mutating func update(
    index: Int,
    part: Int?,
    kind: LLMProgressKind,
    text: LLMProgressText
  ) throws -> [StreamEvent] {
    let key = ExplanationKey(index: index, part: part)
    if items[key]?.isComplete == true {
      return []
    }

    try validateItemLimits(for: key)

    var item =
      items[key]
      ?? ExplanationItem(
        redactor: StreamingProgressText(secretValues: secretValues)
      )
    let otherItemBytes = retainedTextBytes - item.originalTextBytes
    let displayUpdates = redact(text, updating: &item)

    let updatedRetainedBytes = SaturatingArithmetic.sum(otherItemBytes, item.originalTextBytes)
    guard updatedRetainedBytes <= bounds.maximumAccumulatedOutputBytes else {
      throw Self.limitExceeded
    }

    retainedTextBytes = updatedRetainedBytes
    items[key] = item

    return displayUpdates.map { displayText in
      event(key: key, kind: kind, text: displayText)
    }
  }

  mutating func finish() throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    let orderedKeys = items.keys.sorted { left, right in
      if left.index != right.index {
        return left.index < right.index
      }
      return (left.part ?? -1) < (right.part ?? -1)
    }

    for key in orderedKeys where items[key]?.isComplete == false {
      let kind: LLMProgressKind = key.part == nil ? .commentary : .summary
      events += try update(
        index: key.index,
        part: key.part,
        kind: kind,
        text: .complete
      )
    }

    return events
  }
}

// MARK: - Explanation Identity

private extension ChatGPTResponsesProgress {
  struct ExplanationKey: Sendable, Hashable {
    let index: Int
    let part: Int?
  }

  struct ExplanationItem: Sendable {
    var redactor: StreamingProgressText
    var originalTextBytes = 0
    var isComplete = false
  }
}

// MARK: - Explanation Updates

private extension ChatGPTResponsesProgress {
  static let limitExceeded = ProviderError.terminal(
    status: nil,
    message: "the ChatGPT reply exceeded its explanation item or text limit"
  )

  func validateItemLimits(for key: ExplanationKey) throws {
    if let part = key.part, part >= bounds.maximumOutputItems {
      throw Self.limitExceeded
    }

    guard items[key] != nil || items.count < bounds.maximumOutputItems else {
      throw Self.limitExceeded
    }
  }

  func redact(_ text: LLMProgressText, updating item: inout ExplanationItem) -> [LLMProgressText] {
    switch text {
    case .append(let value):
      item.originalTextBytes = SaturatingArithmetic.sum(
        item.originalTextBytes,
        value.utf8.count
      )
      let redactedText = item.redactor.append(value)

      return redactedText.isEmpty ? [] : [.append(redactedText)]
    case .replace(let value):
      item.originalTextBytes = value.utf8.count
      item.redactor = StreamingProgressText(secretValues: secretValues)

      return [.replace(item.redactor.append(value))]
    case .complete:
      let suffix = item.redactor.finish()
      item.isComplete = true

      return suffix.isEmpty ? [.complete] : [.append(suffix), .complete]
    }
  }

  func event(key: ExplanationKey, kind: LLMProgressKind, text: LLMProgressText) -> StreamEvent {
    let suffix: String
    if let part = key.part {
      suffix = "summary:\(part)"
    } else {
      suffix = "commentary"
    }

    return .progress(
      LLMProgressEvent(
        itemID: "responses:\(attemptID):\(key.index):\(suffix)",
        kind: kind,
        text: text
      )
    )
  }
}
