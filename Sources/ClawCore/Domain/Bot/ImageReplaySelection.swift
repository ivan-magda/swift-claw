import Foundation

/// Chooses which cached images a request can afford to carry. Nothing here can fail a turn: an
/// image that does not fit is left behind, and its message keeps the fenced text that names it.
public enum ImageReplaySelection {
  /// Walks newest-first — row ids increase monotonically, so the highest id is the newest image —
  /// and stops at the first image that would cross the aggregate cap. Walking from the newest end
  /// is what makes the omission oldest-first; skipping past the first image that does not fit would
  /// admit a small ancient image over a large recent one, which is the opposite of the rule.
  public static func affordable(
    _ images: [Int64: ImagePart],
    aggregateCap: Int
  ) -> [Int64: ImagePart] {
    let newestFirst = images.sorted { lhs, rhs in
      lhs.key > rhs.key
    }

    var kept: [Int64: ImagePart] = [:]
    var replayBytes = 0

    for (messageID, image) in newestFirst {
      let imageBytes = image.data.count
      guard replayBytes + imageBytes <= aggregateCap else {
        break
      }

      kept[messageID] = image
      replayBytes += imageBytes
    }

    return kept
  }
}
