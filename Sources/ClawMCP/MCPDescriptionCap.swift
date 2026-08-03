import ClawCore

/// The cap on a remote tool's description, cut with the canonical truncation marker.
///
/// Remote descriptions are model-facing text a third party writes, and they ride in every request
/// alongside the built-ins. Truncating bounds what one server can spend of the prompt; it is
/// deliberately not a filter — phrase rewriting fails open, and the durable control over what a
/// remote tool may do is its tier, not a regex over its prose.
public enum MCPDescriptionCap {
  public static let maxGraphemes = 1_200

  public static func cap(
    _ text: String,
    maxGraphemes: Int = MCPDescriptionCap.maxGraphemes
  ) -> String {
    TextTruncation.cap(text, maxGraphemes: maxGraphemes)
  }
}
