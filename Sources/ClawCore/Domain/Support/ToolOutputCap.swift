import Foundation

/// The shared per-tool output cap (ARCHITECTURE.md §5.3): 25 000 tokens enforced in the grapheme
/// domain as 80 000 graphemes (`TokenEstimator.graphemeBudget(forInputTokens: 25_000)`), cut
/// with the canonical truncation marker (not copied).
public enum ToolOutputCap {
  public static let maxGraphemes = 80_000
  /// What an approval prompt shows of a tool's payload: enough to judge the action, short enough
  /// that the prompt still reads as one message.
  public static let approvalPreviewGraphemes = 400
  public static let truncationMarker = TextTruncation.marker

  public static func cap(_ text: String, maxGraphemes: Int = ToolOutputCap.maxGraphemes) -> String {
    TextTruncation.cap(text, maxGraphemes: maxGraphemes)
  }
}
