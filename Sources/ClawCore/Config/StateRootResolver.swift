import Foundation

/// Resolves and creates the state root — the directory every other piece of durable state hangs off.
///
/// Daemon config and the auth commands both come through here, and that is the point: an owner must
/// not be able to have `clawd run` and `clawd auth login` disagree about where their credentials
/// live, or have one of the two create the directory at a mode the other would have refused. Auth
/// commands need this without the rest of `AppConfig`, because they have to work on an installation
/// whose daemon config is invalid — which is exactly why the rule lives here rather than there.
public enum StateRootResolver {
  /// Where state goes when the environment names no path: a dotted directory in the owner's home.
  public static let defaultDirectoryName = ".swift-claw"

  /// Owner-only. The directory holds the runtime key, both secret envelopes, and the database, so
  /// group or world access to it would undo the modes those files are published with.
  static let permissions = 0o700

  /// The state root `rawPath` names, created if it is not already there.
  ///
  /// An absent or blank path resolves to the default rather than to a relative path: copying
  /// `.env.example` verbatim leaves the variable blank, and reading that as "here" would scatter a
  /// state root through whatever directory the daemon happened to be started in.
  ///
  /// - Throws: `ConfigError.unwritableStateRoot` when the directory cannot be created.
  public static func createStateRoot(for rawPath: String?) throws -> URL {
    let trimmedPath = rawPath?.trimmingCharacters(in: .whitespaces)
    let stateRootURL =
      if let path = trimmedPath, !path.isEmpty {
        URL(fileURLWithPath: path, isDirectory: true)
      } else {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          defaultDirectoryName,
          isDirectory: true
        )
      }

    do {
      try FileManager.default.createDirectory(
        at: stateRootURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: permissions]
      )
    } catch {
      throw ConfigError.unwritableStateRoot(stateRootURL.path)
    }

    return stateRootURL
  }
}
