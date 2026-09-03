import Foundation

/// A model reply that is supposed to be one JSON object and nothing else.
///
/// Models wrap JSON in a markdown code fence even when the prompt forbids it. That is a formatting
/// habit, not a different answer, so the fence comes off before a strict decode rather than being
/// allowed to fail one. Removing it is not a repair: it changes no value the model chose, and it
/// buys no second call.
public enum FencedJSONReply {
  private static let fence = "```"

  /// The reply with surrounding whitespace and an outer code fence removed. Everything else is left
  /// exactly as it arrived, so a decoder downstream still sees the model's own bytes.
  public static func unfenced(_ content: String) -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(fence) else {
      return trimmed
    }
    return
      trimmed
      .replacingOccurrences(of: "\(fence)json", with: "")
      .replacingOccurrences(of: fence, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
