import Foundation

public struct ScoredTranscript: Sendable, Equatable {
  public let text: String

  public let confidence: Double?

  public init(text: String, confidence: Double?) {
    self.text = text
    self.confidence = confidence
  }
}

/// Picks the winning transcript when the same audio was run through several candidate locales.
public enum VoiceTranscriptArbiter {
  public static let acceptConfidence = 0.6

  public static let floorConfidence = 0.3

  public static func winner(among candidates: [ScoredTranscript]) -> ScoredTranscript? {
    let scored = candidates.filter { $0.confidence != nil }

    guard let best = scored.max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) }) else {
      return candidates.first
    }

    guard
      let confidence = best.confidence,
      confidence >= floorConfidence
    else {
      return nil
    }

    return best
  }

  public static func averageConfidence(_ values: [Double]) -> Double? {
    if values.isEmpty {
      return nil
    }
    return values.reduce(0, +) / Double(values.count)
  }
}
