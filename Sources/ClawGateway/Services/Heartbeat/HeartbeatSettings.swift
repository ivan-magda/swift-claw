import ClawCore
import Foundation

/// The active heartbeat's startup-resolved dependency bundle. Its presence enables heartbeat;
/// absence disables it. `SchedulerService` never reads config.
public struct HeartbeatSettings: Sendable, Equatable {
  public let intervalMinutes: Int
  public let quietHours: QuietHours
  public let maxPerDay: Int
  public let ownerChatId: Int64
  public let timezone: TimeZone

  public init(
    intervalMinutes: Int,
    quietHours: QuietHours,
    maxPerDay: Int,
    ownerChatId: Int64,
    timezone: TimeZone
  ) {
    self.intervalMinutes = intervalMinutes
    self.quietHours = quietHours
    self.maxPerDay = maxPerDay
    self.ownerChatId = ownerChatId
    self.timezone = timezone
  }

  public static func resolve(config: AppConfig) -> HeartbeatSettings? {
    guard config.heartbeatEnabled else {
      return nil
    }
    guard let ownerChatId = config.heartbeatOwnerChatId else {
      preconditionFailure("AppConfig must resolve one heartbeat owner before composition")
    }

    return HeartbeatSettings(
      intervalMinutes: config.heartbeatIntervalMinutes,
      quietHours: config.heartbeatQuietHours,
      maxPerDay: config.heartbeatMaxPerDay,
      ownerChatId: ownerChatId,
      timezone: config.timezone
    )
  }
}

/// The fixed gateway-authored heartbeat prompt. The contract sentence is pinned verbatim; the
/// checklist is appended as untrusted-tier DATA — the store persists the combined trigger at
/// provenance 'untrusted', so file content can never gain trust here.
enum HeartbeatTemplate {
  static var contractSentence: String {
    """
    Review the checklist below. If something needs the owner's attention, say it concisely. \
    If nothing does, reply exactly \(HeartbeatAck.token).
    """
  }

  static func prompt(checklist: String) -> String {
    "\(contractSentence)\n\n\(checklist)"
  }
}
