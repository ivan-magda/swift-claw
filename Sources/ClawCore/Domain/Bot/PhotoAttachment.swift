import Foundation

/// One rung of Telegram's server-rendered size ladder.
public struct PhotoSize: Sendable, Equatable {
  public let fileId: String
  public let fileUniqueId: String?
  public let width: Int
  public let height: Int
  public let fileSizeBytes: Int64?

  public init(
    fileId: String,
    fileUniqueId: String?,
    width: Int,
    height: Int,
    fileSizeBytes: Int64?
  ) {
    self.fileId = fileId
    self.fileUniqueId = fileUniqueId
    self.width = width
    self.height = height
    self.fileSizeBytes = fileSizeBytes
  }
}

/// The wire-agnostic photo: the whole ladder, so the byte budget rather than the wire decides which
/// rung is fetched. Telegram already downscaled server-side, so choosing a rung is a free resize.
public struct PhotoAttachment: Sendable, Equatable {
  /// The pluralized noun the wire layer and the canned "can't read X yet" reply share.
  public static let mediaKindDescription = "photos"

  public let sizes: [PhotoSize]

  public init(sizes: [PhotoSize]) {
    self.sizes = sizes
  }

  /// The largest rung whose declared size fits, falling back to the largest overall so the transport
  /// cap stays the ground truth. Telegram documents no ordering for the array and its reference
  /// server sorts by expected byte size rather than pixels, so the last element is never assumed.
  public func best(withinBytes cap: Int64) -> PhotoSize? {
    let affordable = sizes.filter { size in
      // A missing file_size is Telegram omitting a zero field, not a declaration of "too big".
      guard let declared = size.fileSizeBytes else {
        return true
      }
      return declared <= cap
    }
    let candidates = affordable.isEmpty ? sizes : affordable
    return candidates.max { lhs, rhs in
      lhs.width * lhs.height < rhs.width * rhs.height
    }
  }
}
