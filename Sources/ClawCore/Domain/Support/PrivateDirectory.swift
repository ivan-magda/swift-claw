import Foundation

public enum PrivateDirectory {
  /// Creates (or adopts) a directory that must stay owner-only. `createDirectory` applies the
  /// permission attribute only to directories it newly creates, so a pre-existing permissive
  /// directory is re-tightened explicitly — silently adopting one would void the privacy
  /// guarantee the caller is documenting.
  public static func ensure(at url: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }
}
