import Foundation

/// Host shell execution: off unless the owner turns it on, and bounded by a timeout ceiling the
/// model cannot argue past.
public struct BashConfig: Sendable, Equatable {
  public let enabled: Bool

  /// An absolute path. Whether the file exists and is executable is settled at registration, not
  /// here — a shell that vanishes after boot must leave the daemon running, not refuse to load.
  public let shellPath: String

  public let defaultTimeoutSeconds: Int
  public let maxTimeoutSeconds: Int

  public static let disabledDefault = BashConfig(
    enabled: false,
    shellPath: AppConfig.EnvDefaults.bashShell,
    defaultTimeoutSeconds: AppConfig.EnvDefaults.bashTimeoutDefaultSeconds,
    maxTimeoutSeconds: AppConfig.EnvDefaults.bashTimeoutMaxSeconds
  )
}

// MARK: - Bash Parsing

extension AppConfig {
  static func parseBashConfig(from env: [String: String]) throws -> BashConfig {
    let enabled = try boolValue(
      env[EnvKey.bashEnabled],
      key: EnvKey.bashEnabled,
      default: false
    )

    let shellPath = try parseBashShell(env[EnvKey.bashShell])

    let maxTimeoutSeconds = try ConfigParse.boundedInt(
      env[EnvKey.bashTimeoutMax],
      default: EnvDefaults.bashTimeoutMaxSeconds,
      range: 1...BashLimits.timeoutCeilingSeconds,
      onInvalid: ConfigError.invalidBashTimeoutMax
    )

    // An owner who lowers only the ceiling gets a default that follows it down; one who names a
    // default above their own ceiling has stated two incompatible things, which is an error.
    let configuredDefault = try ConfigParse.boundedIntOrNil(
      env[EnvKey.bashTimeoutDefault],
      range: 1...maxTimeoutSeconds,
      onInvalid: ConfigError.invalidBashTimeoutDefault
    )
    let defaultTimeoutSeconds =
      configuredDefault ?? min(EnvDefaults.bashTimeoutDefaultSeconds, maxTimeoutSeconds)

    return BashConfig(
      enabled: enabled,
      shellPath: shellPath,
      defaultTimeoutSeconds: defaultTimeoutSeconds,
      maxTimeoutSeconds: maxTimeoutSeconds
    )
  }

  private static func parseBashShell(_ rawValue: String?) throws -> String {
    let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard trimmed.isEmpty == false else {
      return EnvDefaults.bashShell
    }
    guard trimmed.hasPrefix("/") else {
      throw ConfigError.invalidBashShell(trimmed)
    }
    return trimmed
  }
}

public enum BashLimits {
  /// The highest ceiling an owner may configure; a longer command belongs in a background job.
  public static let timeoutCeilingSeconds = 3600
}
