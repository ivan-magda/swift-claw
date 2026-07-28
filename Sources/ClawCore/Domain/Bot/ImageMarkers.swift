/// The stored-content marker for a photo and the assembly-time notice when its bytes are gone.
/// Shared so the router, the builder, and their tests all read one constant.
public enum ImageMarkers {
  public static let barePhoto = "[photo]"
  public static let unavailable = "[the attached photo is no longer available]"
}
