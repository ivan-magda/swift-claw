import ClawCore
import Foundation

/// Tracks bounded display-only explanations. Original replay material stays in the item accumulator.
struct ChatGPTResponsesProgress: Sendable {
  private let bounds: ChatGPTResponsesBounds
  private let secretValues: [String]
  private let attemptID = UUID().uuidString
  private var items: [Key: Item] = [:]
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
    let key = Key(index: index, part: part)
    if items[key]?.completed == true {
      return []
    }
    if let part, part >= bounds.maximumOutputItems {
      throw Self.limitExceeded
    }
    guard items[key] != nil || items.count < bounds.maximumOutputItems else {
      throw Self.limitExceeded
    }
    var item = items[key] ?? Item(redactor: StreamingProgressText(secretValues: secretValues))
    let releasedBytes = retainedTextBytes - item.originalBytes
    let display: LLMProgressText
    var events: [StreamEvent] = []
    switch text {
    case .append(let value):
      item.originalBytes = SaturatingArithmetic.sum(item.originalBytes, value.utf8.count)
      display = .append(item.redactor.append(value))
    case .replace(let value):
      item.originalBytes = value.utf8.count
      item.redactor = StreamingProgressText(secretValues: secretValues)
      display = .replace(item.redactor.append(value))
    case .complete:
      let suffix = item.redactor.finish()
      if suffix.isEmpty == false {
        events.append(event(key: key, kind: kind, text: .append(suffix)))
      }
      item.completed = true
      display = .complete
    }
    let total = SaturatingArithmetic.sum(releasedBytes, item.originalBytes)
    guard total <= bounds.maximumAccumulatedOutputBytes else {
      throw Self.limitExceeded
    }
    retainedTextBytes = total
    items[key] = item
    switch display {
    case .append(let value) where value.isEmpty:
      break
    default:
      events.append(event(key: key, kind: kind, text: display))
    }
    return events
  }

  mutating func finish() throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    let keys = items.keys.sorted { left, right in
      if left.index != right.index {
        return left.index < right.index
      }
      return (left.part ?? -1) < (right.part ?? -1)
    }
    for key in keys where items[key]?.completed == false {
      events += try update(
        index: key.index,
        part: key.part,
        kind: key.part == nil ? .commentary : .summary,
        text: .complete
      )
    }
    return events
  }
}

// MARK: - Explanation Identity

private extension ChatGPTResponsesProgress {
  struct Key: Sendable, Hashable {
    let index: Int
    let part: Int?
  }

  struct Item: Sendable {
    var redactor: StreamingProgressText
    var originalBytes = 0
    var completed = false
  }

  static let limitExceeded = ProviderError.terminal(
    status: nil,
    message: "the ChatGPT reply exceeded its explanation item or text limit"
  )

  func event(key: Key, kind: LLMProgressKind, text: LLMProgressText) -> StreamEvent {
    let suffix =
      key.part.map { part in
        "summary:\(part)"
      } ?? "commentary"
    return .progress(
      LLMProgressEvent(
        itemID: "responses:\(attemptID):\(key.index):\(suffix)",
        kind: kind,
        text: text
      )
    )
  }
}
