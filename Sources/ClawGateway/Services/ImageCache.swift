import ClawCore
import Foundation

/// Recent inbound images, held in memory only. Entries deliberately outlive the run that stored
/// them: a photo sent in one message and questioned in the next must still reach the model as
/// pixels, so nothing here is cleared when a run ends. Entries age out oldest-first once the entry
/// count or the byte ceiling is reached.
///
/// Nothing here is durable — a restart loses every entry, so a caller must be able to carry on
/// without an image it stored earlier.
actor ImageCache {
  private struct Entry {
    let sessionId: Int64
    let messageId: Int64
    let image: ImagePart
  }

  private let maximumImages: Int
  private let maximumBytes: Int
  /// Oldest-first, so eviction takes from the front.
  private var entries: [Entry] = []
  private var bytesHeld = 0

  /// Holds more than any single request can replay, so an image a turn could not afford is still
  /// there for the next one.
  init(
    maximumImages: Int = ImageBounds.maximumCachedImages,
    maximumBytes: Int = ImageBounds.maximumAggregateReplayBytes * 4
  ) {
    self.maximumImages = maximumImages
    self.maximumBytes = maximumBytes
  }

  func store(_ image: ImagePart, sessionId: Int64, messageId: Int64) {
    let existing = entries.firstIndex { entry in
      entry.sessionId == sessionId && entry.messageId == messageId
    }
    if let existing {
      bytesHeld -= entries[existing].image.data.count
      entries.remove(at: existing)
    }

    entries.append(Entry(sessionId: sessionId, messageId: messageId, image: image))
    bytesHeld += image.data.count

    // A lone image over the ceiling is kept rather than evicted into nothing: refusing it belongs to
    // replay selection, which can drop it for one request without losing it for the next.
    while entries.count > maximumImages || (bytesHeld > maximumBytes && entries.count > 1) {
      let evicted = entries.removeFirst()
      bytesHeld -= evicted.image.data.count
    }
  }

  func images(sessionId: Int64) -> [Int64: ImagePart] {
    var found: [Int64: ImagePart] = [:]
    for entry in entries where entry.sessionId == sessionId {
      found[entry.messageId] = entry.image
    }
    return found
  }
}
