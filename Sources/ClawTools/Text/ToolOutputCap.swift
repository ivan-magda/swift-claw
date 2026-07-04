import Foundation

/// The shared per-tool output cap (§15): 25 000 tokens enforced in the grapheme domain as
/// 80 000 graphemes (`TokenEstimator.graphemeBudget(forInputTokens: 25_000)`), cut with the
/// same literal marker `BudgetFitter` uses.
public enum ToolOutputCap {
  public static let maxGraphemes = 80_000
  public static let truncationMarker = "…[truncated]"

  public static func cap(_ text: String, maxGraphemes: Int = ToolOutputCap.maxGraphemes) -> String {
    guard text.count > maxGraphemes else {
      return text
    }
    guard maxGraphemes > truncationMarker.count else {
      return String(truncationMarker.prefix(maxGraphemes))
    }
    return String(text.prefix(maxGraphemes - truncationMarker.count)) + truncationMarker
  }
}
