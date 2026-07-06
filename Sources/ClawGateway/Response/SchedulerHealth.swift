import ClawCore
import Foundation

/// Renders doctor's scheduler/heartbeat rows from persisted `scheduler_state` + config. Pure so
/// the rendering is unit-testable; doctor is a separate process, so ONLY persisted state is
/// visible to it (D8) — `dueCount` arrives from a live query at call time, never from storage.
public enum SchedulerHealth {
  public struct Row: Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
      self.key = key
      self.value = value
    }
  }

  public static func rows(
    state: SchedulerState,
    dueCount: Int?,
    proactiveTodayUSD: Double?,
    proactivePerDayUSD: Double,
    heartbeatEnabled: Bool,
    heartbeatMaxPerDay: Int,
    timezone: TimeZone,
    now: Date
  ) -> [Row] {
    let misfire: String
    if let lastMisfireAt = state.lastMisfireAt {
      misfire = "\(lastMisfireAt) (skipped \(state.lastMisfireSkippedCount))"
    } else {
      misfire = "none"
    }
    let todayCount = heartbeatCountToday(state: state, timezone: timezone, now: now)
    // Spec §11: a proactive-cap trip is visible here even while global spend is under its cap.
    let proactiveSpend =
      proactiveTodayUSD.map { spent in USD.display(spent) } ?? "unknown"

    return [
      Row(
        key: "scheduler.last_tick_at",
        value: state.lastTickAt.map(String.init(describing:)) ?? "never"
      ),
      Row(key: "scheduler.due_count", value: dueCount.map(String.init) ?? "unknown"),
      Row(key: "scheduler.last_misfire", value: misfire),
      Row(
        key: "spend.proactive_today_usd",
        value: "\(proactiveSpend)/\(USD.display(proactivePerDayUSD))"
      ),
      Row(key: "heartbeat.enabled", value: heartbeatEnabled ? "on" : "off"),
      Row(
        key: "heartbeat.last",
        value: state.lastHeartbeatAt.map(String.init(describing:)) ?? "never"
      ),
      Row(key: "heartbeat.today", value: "\(todayCount)/\(heartbeatMaxPerDay)"),
    ]
  }

  /// The stored day counter counts for "today" only when its day stamp (kept in CLAW_TIMEZONE,
  /// §4.3 — the cap's day boundary aligns with quiet hours, not UTC) matches now's local day; a
  /// stale stamp reads as zero, matching the cap's rollover semantics.
  static func heartbeatCountToday(state: SchedulerState, timezone: TimeZone, now: Date) -> Int {
    guard state.heartbeatCountDay == dayString(for: now, timezone: timezone) else {
      return 0
    }
    return state.heartbeatCount
  }

  /// "YYYY-MM-DD" in the given zone — the `scheduler_state.heartbeat_count_day` stamp format.
  static func dayString(for instant: Date, timezone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    let components = calendar.dateComponents([.year, .month, .day], from: instant)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }
}
