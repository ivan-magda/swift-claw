import Foundation

/// One locale lane's outcome: the transcript plus the engine's average per-run confidence,
/// nil when the engine emitted no confidence data at all.
public struct ScoredTranscript: Sendable, Equatable {
  public let text: String
  public let confidence: Double?

  public init(text: String, confidence: Double?) {
    self.text = text
    self.confidence = confidence
  }
}

/// Picks the winning transcript when the same audio was run through several candidate locales.
/// Wrong-language output carries no error — the engine emits garbage as success — so selection
/// keys on the engine's per-run confidence. Measured on-host separation (2026-07-18 spike, both
/// engine generations): a matching language averages ≥ 0.84, a mismatched one ≤ 0.21, including
/// mismatches that read as plausible text and would pass any transcript-shape heuristic.
public enum VoiceTranscriptArbiter {
  /// A lane at or above this average is a clear match: accept it without running later lanes.
  public static let acceptConfidence = 0.6
  /// Below this average every lane is treated as "no language matched", never sent to the LLM.
  public static let floorConfidence = 0.3

  /// The winner among candidates listed in configured-locale priority order, nil when every
  /// measurable candidate falls below the floor. Candidates without confidence data lose to any
  /// measurable one; if no candidate is measurable the first wins, preserving single-locale
  /// behavior on an engine that emits no confidence.
  public static func winner(among candidates: [ScoredTranscript]) -> ScoredTranscript? {
    let scored = candidates.filter { $0.confidence != nil }
    guard let best = scored.max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) }) else {
      return candidates.first
    }
    guard let confidence = best.confidence, confidence >= floorConfidence else {
      return nil
    }
    return best
  }

  public static func averageConfidence(_ values: [Double]) -> Double? {
    guard !values.isEmpty else {
      return nil
    }
    return values.reduce(0, +) / Double(values.count)
  }
}
