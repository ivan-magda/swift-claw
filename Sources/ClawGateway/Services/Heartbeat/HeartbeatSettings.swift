import ClawCore
import Foundation

/// The heartbeat's startup-resolved dependency bundle. Resolved ONCE from `AppConfig`
/// at the composition root — `SchedulerService` never reads config. `ownerChatId` is the
/// config-derived delivery target; `AppConfig.load` rejects enabled-without-one-owner, so a nil
/// target on an enabled bundle is unreachable in a validly-booted daemon (the tick branch still
/// fails closed on it — `disabled_mid_flight`).
public struct HeartbeatSettings: Sendable, Equatable {
  public let enabled: Bool
  public let intervalMinutes: Int
  public let quietHours: QuietHours
  public let maxPerDay: Int
  public let ownerChatId: Int64?
  public let timezone: TimeZone

  public init(
    enabled: Bool,
    intervalMinutes: Int,
    quietHours: QuietHours,
    maxPerDay: Int,
    ownerChatId: Int64?,
    timezone: TimeZone
  ) {
    self.enabled = enabled
    self.intervalMinutes = intervalMinutes
    self.quietHours = quietHours
    self.maxPerDay = maxPerDay
    self.ownerChatId = ownerChatId
    self.timezone = timezone
  }

  /// The spec defaults with the heartbeat OFF — the safe bundle for tests and any
  /// composition that does not heartbeat.
  public static let disabled = HeartbeatSettings(
    enabled: false,
    intervalMinutes: 60,
    quietHours: QuietHours(startMinuteOfDay: 22 * 60, endMinuteOfDay: 9 * 60),
    maxPerDay: 8,
    ownerChatId: nil,
    timezone: .current
  )

  public static func resolve(config: AppConfig) -> HeartbeatSettings {
    HeartbeatSettings(
      enabled: config.heartbeatEnabled,
      intervalMinutes: config.heartbeatIntervalMinutes,
      quietHours: config.heartbeatQuietHours,
      maxPerDay: config.heartbeatMaxPerDay,
      ownerChatId: config.allowlist.count == 1 ? config.allowlist.first : nil,
      timezone: config.timezone
    )
  }
}

/// The fixed gateway-authored heartbeat prompt. The contract sentence is pinned verbatim; the
/// checklist is appended as untrusted-tier DATA — the store persists the combined trigger at
/// provenance 'untrusted', so file content can never gain trust here.
enum HeartbeatTemplate {
  static let contractSentence = """
    Review the checklist below. If something needs the owner's attention, say it concisely. \
    If nothing does, reply exactly HEARTBEAT_OK.
    """

  static func prompt(checklist: String) -> String {
    "\(contractSentence)\n\n\(checklist)"
  }
}
