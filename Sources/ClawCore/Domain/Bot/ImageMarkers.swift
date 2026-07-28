/// The stored-content marker for a photo and the assembly-time notice when its bytes are gone.
/// Shared so the router, the builder, and their tests all read one constant.
public enum ImageMarkers {
  public static let barePhoto = "[photo]"
  public static let unavailable = "[the attached photo is no longer available]"

  /// What a photo row persists as. The marker always leads, captioned or not: image bytes are never
  /// stored, so this string is the only surviving evidence that the row carried a photo. A caption
  /// that merely replaced the marker would erase that evidence on the commonest path.
  public static func photoContent(caption: String?) -> String {
    guard let caption, caption.isEmpty == false else {
      return barePhoto
    }
    return "\(barePhoto) \(caption)"
  }

  /// Whether stored content came from `photoContent`. Kept beside it so the two halves of the
  /// round-trip cannot drift apart.
  public static func marksPhoto(_ content: String) -> Bool {
    content.hasPrefix(barePhoto)
  }
}
