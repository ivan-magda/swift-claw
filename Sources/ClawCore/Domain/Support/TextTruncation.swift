public enum TextTruncation {
  public static let marker = "…[truncated]"

  /// Fit-within-cap truncation: the marker replaces the tail so the result never exceeds
  /// `maxGraphemes` — including the degenerate cap smaller than the marker itself.
  public static func cap(_ text: String, maxGraphemes: Int) -> String {
    guard text.count > maxGraphemes else {
      return text
    }

    guard maxGraphemes > marker.count else {
      return String(marker.prefix(maxGraphemes))
    }

    return String(text.prefix(maxGraphemes - marker.count)) + marker
  }
}
