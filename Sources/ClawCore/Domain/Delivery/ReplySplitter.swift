/// Splits an assistant reply into Telegram-sendable chunks. Telegram caps a single (rich)
/// message at 32 768 characters, so a longer answer becomes several outbox chunks. Splitting is
/// grapheme-based so a multi-scalar character (emoji, flag, combined mark) is never torn across a
/// boundary, and only happens when the text actually exceeds the limit — at or under it the text
/// passes through unchanged. Empty input yields no chunks (never a zero-length send).
public enum ReplySplitter {
  /// Telegram's per-message character ceiling for the rich send path.
  public static let limit = 32_768

  public static func split(text: String, limit: Int = limit) -> [String] {
    guard !text.isEmpty else {
      return []
    }
    guard text.count > limit else {
      return [text]
    }

    var chunks = [String]()
    var current = ""
    current.reserveCapacity(limit)
    var graphemeCount = 0

    for character in text {
      current.append(character)
      graphemeCount += 1
      if graphemeCount == limit {
        chunks.append(current)
        current = ""
        graphemeCount = 0
      }
    }

    if !current.isEmpty {
      chunks.append(current)
    }

    return chunks
  }
}
