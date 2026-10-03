import Foundation

public struct VoiceConfig: Sendable, Equatable {
  public let enabled: Bool

  public let localeIdentifiers: [String]

  public init(enabled: Bool, localeIdentifiers: [String]) {
    self.enabled = enabled
    self.localeIdentifiers = localeIdentifiers
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

    var seen = Set<String>()
    let localeIdentifiers = (env[EnvKey.voiceLocales] ?? "")
      .split(separator: ",")
      .map { locale in
        locale.trimmingCharacters(in: .whitespaces)
      }
      .filter { locale in
        !locale.isEmpty && seen.insert(locale).inserted
      }

    return VoiceConfig(
      enabled: enabled,
      localeIdentifiers: localeIdentifiers.isEmpty ? [EnvDefaults.voiceLocale] : localeIdentifiers
    )
  }
}
