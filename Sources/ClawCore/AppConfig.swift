import Foundation

public struct AppConfig: Sendable, Equatable {
  enum EnvKey {
    static let botToken = "CLAW_TELEGRAM_BOT_TOKEN"
    static let allowlist = "CLAW_ALLOWLIST"
    static let stateRoot = "CLAW_STATE_ROOT"
    static let pollTimeout = "CLAW_POLL_TIMEOUT"
  }

  private enum EnvDefaults {
    static let pollTimeoutSeconds = 30
    static let stateDirectoryName = ".swift-claw"
  }

  private static let stateRootPermissions = 0o700

  public let botToken: String
  public let allowlist: Set<Int64>
  public let stateRoot: URL
  public let pollTimeoutSeconds: Int

  public init(botToken: String, allowlist: Set<Int64>, stateRoot: URL, pollTimeoutSeconds: Int) {
    self.botToken = botToken
    self.allowlist = allowlist
    self.stateRoot = stateRoot
    self.pollTimeoutSeconds = pollTimeoutSeconds
  }

  /// Loads and validates config from the environment, throwing `ConfigError` on a missing token,
  /// a non-numeric allowlist entry, or an uncreatable state root.
  /// An empty allowlist is allowed so onboarding can still boot.
  public static func load(environment env: [String: String]) throws -> AppConfig {
    guard let botToken = env[EnvKey.botToken], !botToken.isEmpty else {
      throw ConfigError.missingBotToken
    }

    let allowlist = try parseAllowlist(env[EnvKey.allowlist])
    let stateRoot = try createStateRootURL(for: env[EnvKey.stateRoot])
    let pollTimeoutSeconds =
      env[EnvKey.pollTimeout].flatMap(Int.init) ?? EnvDefaults.pollTimeoutSeconds

    return AppConfig(
      botToken: botToken,
      allowlist: allowlist,
      stateRoot: stateRoot,
      pollTimeoutSeconds: pollTimeoutSeconds
    )
  }

  private static func parseAllowlist(_ allowlist: String?) throws -> Set<Int64> {
    guard
      let allowlist = allowlist?.trimmingCharacters(in: .whitespaces),
      !allowlist.isEmpty
    else {
      return []
    }

    var result = Set<Int64>()

    for part in allowlist.split(separator: ",") {
      let trimmed = part.trimmingCharacters(in: .whitespaces)

      guard let id = Int64(trimmed) else {
        throw ConfigError.invalidAllowlist(trimmed)
      }

      result.insert(id)
    }

    return result
  }

  private static func createStateRootURL(for path: String?) throws -> URL {
    let stateRootURL =
      if let path {
        URL(fileURLWithPath: path, isDirectory: true)
      } else {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          EnvDefaults.stateDirectoryName
        )
      }

    do {
      try FileManager.default.createDirectory(
        at: stateRootURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: stateRootPermissions]
      )
    } catch {
      throw ConfigError.unwritableStateRoot(stateRootURL.path)
    }

    return stateRootURL
  }
}
