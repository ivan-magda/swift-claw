import Foundation

public struct VoiceConfig: Sendable, Equatable {
  public let enabled: Bool
  /// BCP-47 identifier the transcriber resolves against the installed speech stack at runtime
  /// (`en-US` default). Resolution failure is a per-message typed error, not a boot failure —
  /// which locales exist is a property of the host's speech assets, not of the config.
  public let localeIdentifier: String

  public init(enabled: Bool, localeIdentifier: String) {
    self.enabled = enabled
    self.localeIdentifier = localeIdentifier
  }
}

// MARK: - Voice Parsing

extension AppConfig {
  static func parseVoiceConfig(from env: [String: String]) throws -> VoiceConfig {
    let enabled = try boolValue(
      env[EnvKey.voiceTranscription],
      key: EnvKey.voiceTranscription,
      default: true
    )

    let rawLocale = env[EnvKey.voiceLocale]?.trimmingCharacters(in: .whitespaces) ?? ""
    let localeIdentifier = rawLocale.isEmpty ? EnvDefaults.voiceLocale : rawLocale

    return VoiceConfig(enabled: enabled, localeIdentifier: localeIdentifier)
  }
}
