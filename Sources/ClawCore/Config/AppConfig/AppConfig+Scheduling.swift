import Foundation

// MARK: - Scheduling and Heartbeat Parsing

extension AppConfig {
  /// The scheduling timezone: absent/blank falls back to the host's current zone; a present
  /// value must resolve via `TimeZone(identifier:)`, else fail-closed.
  static func parseTimezone(from raw: String?) throws -> TimeZone {
    let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !trimmed.isEmpty else {
      return TimeZone.current
    }

    guard let zone = TimeZone(identifier: trimmed) else {
      throw ConfigError.invalidTimezone(trimmed)
    }

    return zone
  }

  /// An `Int` override with a lower bound: `fallback` when absent/blank, else
  /// `invalidScheduling` on a non-numeric or below-minimum value.
  static func boundedInt(
    _ raw: String?,
    key: String,
    default fallback: Int,
    minimum: Int
  ) throws -> Int {
    try ConfigParse.boundedInt(raw, default: fallback, range: minimum...Int.max) { value in
      ConfigError.invalidScheduling(key: key, value: value)
    }
  }

  struct HeartbeatSettings {
    let enabled: Bool
    let intervalMinutes: Int
    let quietHours: QuietHours
    let maxPerDay: Int
  }

  static func parseHeartbeat(
    from env: [String: String],
    allowlist: Set<Int64>
  ) throws -> HeartbeatSettings {
    let enabled = try boolValue(
      env[EnvKey.heartbeatEnabled],
      key: EnvKey.heartbeatEnabled,
      default: false
    )
    // The heartbeat delivers to the config-resolved owner DM (and the same target
    // serves the boot-reconcile crash notice). Enabling it without exactly one allowlisted id
    // is a config ERROR (fail closed at load + doctor --check-config), never a runtime guess.
    if enabled, allowlist.count != 1 {
      throw ConfigError.heartbeatOwnerUnresolved(allowlistCount: allowlist.count)
    }

    return HeartbeatSettings(
      enabled: enabled,
      intervalMinutes: try boundedInt(
        env[EnvKey.heartbeatIntervalMinutes],
        key: EnvKey.heartbeatIntervalMinutes,
        default: EnvDefaults.heartbeatIntervalMinutes,
        minimum: 15
      ),
      quietHours: try parseQuietHours(from: env[EnvKey.heartbeatQuietHours]),
      maxPerDay: try boundedInt(
        env[EnvKey.heartbeatMaxPerDay],
        key: EnvKey.heartbeatMaxPerDay,
        default: EnvDefaults.heartbeatMaxPerDay,
        minimum: 1
      )
    )
  }
}

// MARK: - Quiet Hours Validation

private extension AppConfig {
  static func parseQuietHours(from raw: String?) throws -> QuietHours {
    let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""

    if trimmed.isEmpty {
      if let fallback = QuietHours.parse(EnvDefaults.heartbeatQuietHours) {
        return fallback
      }
      throw ConfigError.invalidQuietHours(EnvDefaults.heartbeatQuietHours)
    }

    guard let window = QuietHours.parse(trimmed) else {
      throw ConfigError.invalidQuietHours(trimmed)
    }

    return window
  }
}
