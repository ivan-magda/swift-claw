import Foundation

/// The image formats every supported vision route accepts. A raw mime string never crosses this
/// seam — the wire encoders read `mimeType` from the case.
public enum ImageMediaType: String, Sendable, Equatable, CaseIterable {
  case jpeg
  case png
  case gif
  case webp

  public var mimeType: String {
    "image/\(rawValue)"
  }

  /// Identifies a payload by its leading bytes. Telegram's `mime_type` is sender-declared and the
  /// download is an opaque body, so the bytes themselves are the only trustworthy signal — and a
  /// payload that is not an image must never reach a model.
  public static func sniff(_ bytes: Data) -> ImageMediaType? {
    let prefix = [UInt8](bytes.prefix(16))

    if prefix.starts(with: [0xFF, 0xD8, 0xFF]) {
      return .jpeg
    }

    if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
      return .png
    }

    if prefix.starts(with: [0x47, 0x49, 0x46, 0x38]) {
      return .gif
    }

    let isRIFF = prefix.starts(with: [0x52, 0x49, 0x46, 0x46])
    guard isRIFF, prefix.count >= 12 else {
      return nil
    }

    return Array(prefix[8..<12]) == [0x57, 0x45, 0x42, 0x50] ? .webp : nil
  }
}

/// Caps and budgets for inbound images. `maximumImageBytes` is deliberately one number shared by
/// the download ceiling and the replay budget: a photo too large to replay is never downloaded, and
/// rung selection picks a smaller one instead.
public enum ImageBounds {
  public static let patchEdgePixels = 28
  public static let maximumVisualTokens = 4_784
  public static let maximumImageBytes = 512 * 1024
  public static let maximumAggregateReplayBytes = 1024 * 1024
  public static let maximumCachedImages = 8
}

/// A downloaded image, decoded only far enough to know what it is and how big it is.
public struct ImagePart: Sendable, Equatable {
  public let data: Data
  public let mediaType: ImageMediaType
  public let width: Int
  public let height: Int

  public init(data: Data, mediaType: ImageMediaType, width: Int, height: Int) {
    self.data = data
    self.mediaType = mediaType
    self.width = width
    self.height = height
  }

  /// A deliberately high estimate: the published 28px patch grid over-counts the 32px grid the
  /// OpenAI families use, so one number reserves safely on every route and errs toward refusing a
  /// run rather than overspending on it.
  public var visualTokenEstimate: Int {
    let edge = ImageBounds.patchEdgePixels
    let columns = max(1, (width + edge - 1) / edge)
    let rows = max(1, (height + edge - 1) / edge)
    return min(columns * rows, ImageBounds.maximumVisualTokens)
  }

  /// The `data:` URL both wire adapters embed. A remote URL is never sent: the Telegram file URL
  /// carries the bot token, and providers will happily fetch what they are handed.
  public var dataURL: String {
    "data:\(mediaType.mimeType);base64,\(data.base64EncodedString())"
  }
}
