import ClawCore
import Foundation

/// Renders doctor's scheduler/heartbeat rows from persisted `scheduler_state` + config. Pure so
/// the rendering is unit-testable; doctor is a separate process, so ONLY persisted state is
/// visible to it — `dueCount` arrives from a live query at call time, never from storage.
public enum SchedulerHealth {
  /// One doctor-time observation: persisted `scheduler_state` plus the live/config values that
  /// contextualize it (due query result, proactive spend vs. its cap, heartbeat settings).
  public struct Snapshot: Sendable {
    public let state: HealthValue<SchedulerState>

    public let dueCount: HealthValue<Int>

    public let proactiveTodayUSD: HealthValue<Double>
    public let proactivePerDayUSD: Double

    public let heartbeatEnabled: Bool
    public let heartbeatMaxPerDay: Int

    public let timezone: TimeZone
    public let now: Date

    public init(
      state: HealthValue<SchedulerState>,
      dueCount: HealthValue<Int>,
      proactiveTodayUSD: HealthValue<Double>,
      proactivePerDayUSD: Double,
      heartbeatEnabled: Bool,
      heartbeatMaxPerDay: Int,
      timezone: TimeZone,
      now: Date
    ) {
      self.state = state

      self.dueCount = dueCount

      self.proactiveTodayUSD = proactiveTodayUSD
      self.proactivePerDayUSD = proactivePerDayUSD

      self.heartbeatEnabled = heartbeatEnabled
      self.heartbeatMaxPerDay = heartbeatMaxPerDay

      self.timezone = timezone
      self.now = now
    }
  }

  public static func rows(_ snapshot: Snapshot) -> [DoctorReport.Check] {
    [
      .storeRead(snapshot.state, key: "scheduler.last_tick_at", group: .scheduler) { state in
        state.lastTickAt.map(String.init(describing:)) ?? "never"
      },
      .storeRead(
        snapshot.dueCount,
        key: "scheduler.due_count",
        group: .scheduler,
        isHeadline: true
      ) { count in
        String(count)
      },
      .storeRead(snapshot.state, key: "scheduler.last_misfire", group: .scheduler) { state in
        guard let lastMisfireAt = state.lastMisfireAt else {
          return "none"
        }
        return "\(lastMisfireAt) (skipped \(state.lastMisfireSkippedCount))"
      },
      .storeRead(
        snapshot.proactiveTodayUSD,
        key: "spend.proactive_today_usd",
        group: .scheduler
      ) { spent in
        "\(USD.display(spent))/\(USD.display(snapshot.proactivePerDayUSD))"
      },
      check("heartbeat.enabled", snapshot.heartbeatEnabled ? "on" : "off"),
      .storeRead(snapshot.state, key: "heartbeat.last", group: .scheduler) { state in
        state.lastHeartbeatAt.map(String.init(describing:)) ?? "never"
      },
      .storeRead(snapshot.state, key: "heartbeat.today", group: .scheduler) { state in
        let todayCount = heartbeatCountToday(
          state: state,
          timezone: snapshot.timezone,
          now: snapshot.now
        )
        return "\(todayCount)/\(snapshot.heartbeatMaxPerDay)"
      },
    ]
  }

  /// The stored day counter counts for "today" only when its day stamp (kept in CLAW_TIMEZONE —
  /// the cap's day boundary aligns with quiet hours, not UTC) matches now's local day; a
  /// stale stamp reads as zero, matching the cap's rollover semantics.
  static func heartbeatCountToday(state: SchedulerState, timezone: TimeZone, now: Date) -> Int {
    guard state.heartbeatCountDay == dayString(for: now, timezone: timezone) else {
      return 0
    }
    return state.heartbeatCount
  }

  /// "YYYY-MM-DD" in the given zone — the `scheduler_state.heartbeat_count_day` stamp format.
  static func dayString(for instant: Date, timezone: TimeZone) -> String {
    instant.wallClockDay(in: timezone)
  }
}

// MARK: - Check Builder

private extension SchedulerHealth {
  static func check(
    _ key: String,
    _ value: String,
    headline: Bool = false
  ) -> DoctorReport.Check {
    DoctorReport.Check(key: key, value: value, ok: true, group: .scheduler, isHeadline: headline)
  }
}
