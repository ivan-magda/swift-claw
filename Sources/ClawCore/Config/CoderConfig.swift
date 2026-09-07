import Foundation

public struct CoderConfig: Sendable, Equatable {
  public enum Defaults {
    public static let enabled = false
    public static let maxConcurrentJobs = 1
    public static let jobTimeoutSeconds = 1800
    public static let executable = "codex"
  }

  public static let maximumJobTimeoutSeconds = 86_400

  public let enabled: Bool
  public let maxConcurrentJobs: Int
  public let jobTimeoutSeconds: Int
  public let executable: String
  public let profile: String?
  public let configHome: String?
  public let searchPath: String?

  public init(
    enabled: Bool,
    maxConcurrentJobs: Int,
    jobTimeoutSeconds: Int,
    executable: String,
    profile: String?,
    configHome: String?,
    searchPath: String? = nil
  ) {
    self.enabled = enabled
    self.maxConcurrentJobs = maxConcurrentJobs
    self.jobTimeoutSeconds = jobTimeoutSeconds
    self.executable = executable
    self.profile = profile
    self.configHome = configHome
    self.searchPath = searchPath
  }

  /// Parses operator settings without resolving executables or accessing Codex configuration.
  public static func load(environment: [String: String]) throws(ConfigError) -> CoderConfig {
    let values = try nonemptySettings(environment)
    let executable = values[AppConfig.EnvKey.coderExecutable] ?? Defaults.executable

    guard validExecutable(executable) else {
      throw .invalidCoderSetting(key: AppConfig.EnvKey.coderExecutable)
    }

    let configHome = values[AppConfig.EnvKey.coderConfigHome]
    if let configHome, !configHome.hasPrefix("/") {
      throw .invalidCoderSetting(key: AppConfig.EnvKey.coderConfigHome)
    }

    let searchPath = values[AppConfig.EnvKey.coderPath]
    if let searchPath {
      let absolute =
        searchPath
        .split(separator: ":", omittingEmptySubsequences: false)
        .allSatisfy { $0.hasPrefix("/") }
      guard absolute else {
        throw .invalidCoderSetting(key: AppConfig.EnvKey.coderPath)
      }
    }

    return CoderConfig(
      enabled: try AppConfig.boolValue(
        values[AppConfig.EnvKey.coderEnabled],
        key: AppConfig.EnvKey.coderEnabled,
        default: Defaults.enabled
      ),
      maxConcurrentJobs: try ConfigParse.boundedInt(
        values[AppConfig.EnvKey.coderMaxConcurrentJobs],
        default: Defaults.maxConcurrentJobs,
        range: 1...Int.max,
        onInvalid: { _ in
          .invalidCoderSetting(key: AppConfig.EnvKey.coderMaxConcurrentJobs)
        }
      ),
      jobTimeoutSeconds: try ConfigParse.boundedInt(
        values[AppConfig.EnvKey.coderJobTimeoutSeconds],
        default: Defaults.jobTimeoutSeconds,
        range: 1...maximumJobTimeoutSeconds,
        onInvalid: { _ in
          .invalidCoderSetting(key: AppConfig.EnvKey.coderJobTimeoutSeconds)
        }
      ),
      executable: executable,
      profile: values[AppConfig.EnvKey.coderProfile],
      configHome: configHome,
      searchPath: searchPath
    )
  }
}

// MARK: - Scalar Validation

private extension CoderConfig {
  static func nonemptySettings(
    _ environment: [String: String]
  ) throws(ConfigError) -> [String: String] {
    let keys = [
      AppConfig.EnvKey.coderEnabled, AppConfig.EnvKey.coderMaxConcurrentJobs,
      AppConfig.EnvKey.coderJobTimeoutSeconds, AppConfig.EnvKey.coderExecutable,
      AppConfig.EnvKey.coderProfile, AppConfig.EnvKey.coderConfigHome,
      AppConfig.EnvKey.coderPath,
    ]

    var values: [String: String] = [:]
    for key in keys {
      guard let raw = environment[key] else {
        continue
      }

      let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

      guard !value.isEmpty,
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw .invalidCoderSetting(key: key)
      }

      values[key] = value
    }

    return values
  }

  static func validExecutable(_ value: String) -> Bool {
    if value.hasPrefix("/") {
      return true
    }

    guard !value.hasPrefix("-"), !value.contains("/") else {
      return false
    }

    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    return value.unicodeScalars.allSatisfy { scalar in
      allowedCharacters.contains(scalar)
    }
  }
}
