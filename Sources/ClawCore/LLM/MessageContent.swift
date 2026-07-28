import Foundation

/// One message's content as ordered parts. Modeled for every role, not just `.user`: tool
/// observations are text-only today, but the type must not need re-cutting the first time a tool
/// wants to hand back an image.
public struct MessageContent: Sendable, Equatable {
  public enum Part: Sendable, Equatable {
    case text(String)
    case image(ImagePart)
  }

  public let parts: [Part]

  public init(parts: [Part]) {
    self.parts = parts
  }

  public init(_ text: String) {
    self.parts = [.text(text)]
  }

  /// Every text part joined. Callers that budget by character count read this and are unaffected by
  /// images, which cost tokens rather than graphemes and are reserved for separately.
  public var text: String {
    parts
      .compactMap { part -> String? in
        switch part {
        case .text(let value): value
        case .image: nil
        }
      }
      .joined(separator: "\n")
  }

  public var images: [ImagePart] {
    parts.compactMap { part -> ImagePart? in
      switch part {
      case .image(let image): image
      case .text: nil
      }
    }
  }

  /// True when this is exactly one text part. Callers that can only handle a lone string ask this;
  /// a wire encoder choosing between a string and a parts array should ask `images.isEmpty` instead,
  /// because a multi-part text-only content still fits the string form.
  public var isPlainText: Bool {
    guard parts.count == 1, case .text = parts[0] else {
      return false
    }
    return true
  }
}
