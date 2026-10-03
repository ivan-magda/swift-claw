/// A transient frame and an optional renderer-owned compatibility alternative.
/// Both representations preserve the same answer; only owned progress decoration may differ.
public struct RichDraft: Sendable, Equatable {
  public let markdown: String
  public let fallbackMarkdown: String?

  public init(markdown: String, fallbackMarkdown: String? = nil) {
    self.markdown = markdown
    self.fallbackMarkdown = fallbackMarkdown
  }
}

extension RichDraft {
  public init(markdown: String) {
    self.init(markdown: markdown, fallbackMarkdown: nil)
  }
}
