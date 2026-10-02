public enum LLMProgressKind: Sendable, Equatable {
  case commentary
  case summary
}

public enum LLMProgressText: Sendable, Equatable {
  case append(String)
  case replace(String)
  case complete
}

/// A display explanation item scoped to one provider attempt. Completion flushes its safe pending
/// suffix; it never completes inference or contributes answer text.
public struct LLMProgressEvent: Sendable, Equatable {
  public let itemID: String
  public let kind: LLMProgressKind
  public let text: LLMProgressText

  public init(itemID: String, kind: LLMProgressKind, text: LLMProgressText) {
    self.itemID = itemID
    self.kind = kind
    self.text = text
  }
}
