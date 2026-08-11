import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct SchedulerHealthTests {
  /// 2026-07-06 05:00:00 UTC — 07:00 in Europe/Berlin (CEST), so the local day is 2026-07-06.
  private let now = Date(timeIntervalSince1970: 1_783_314_000)
  // force_unwrapping is `error` project-wide with no Tests exclusion (.swiftlint.yml); `Europe/
  // Berlin` always resolves at runtime, so `.gmt` here is unreachable — matches sibling tests.
  private let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt

  private func value(_ rows: [DoctorReport.Check], _ key: String) -> String? {
    rows.first { row in row.key == key }?.value
  }

  @Test func emptyStateRendersNeverAndZeroCounts() {
    // given — a freshly-migrated scheduler_state: nothing has ever ticked
    let state = SchedulerState(
      lastTickAt: nil,
      lastMisfireAt: nil,
      lastMisfireSkippedCount: 0,
      lastHeartbeatAt: nil,
      heartbeatCountDay: nil,
      heartbeatCount: 0
    )

    // when
    let rows = SchedulerHealth.rows(
      SchedulerHealth.Snapshot(
        state: .available(state),
        dueCount: .available(0),
        proactiveTodayUSD: .available(0),
        proactivePerDayUSD: 2.0,
        heartbeatEnabled: false,
        heartbeatMaxPerDay: 8,
        timezone: berlin,
        now: now
      )
    )

    // then
    #expect(value(rows, "scheduler.last_tick_at") == "never")
    #expect(value(rows, "scheduler.due_count") == "0")
    #expect(value(rows, "scheduler.last_misfire") == "none")
    #expect(value(rows, "spend.proactive_today_usd") == "0.00/2.00")
    #expect(value(rows, "heartbeat.enabled") == "off")
    #expect(value(rows, "heartbeat.last") == "never")
    #expect(value(rows, "heartbeat.today") == "0/8")
  }

  @Test func populatedStateRendersTimestampsMisfireCountAndTodayCount() {
    // given — a tick a minute ago, one misfire that skipped 5, 3 heartbeats stamped for TODAY
    // in the configured zone
    let state = SchedulerState(
      lastTickAt: now.addingTimeInterval(-60),
      lastMisfireAt: now.addingTimeInterval(-3_600),
      lastMisfireSkippedCount: 5,
      lastHeartbeatAt: now.addingTimeInterval(-120),
      heartbeatCountDay: "2026-07-06",
      heartbeatCount: 3
    )

    // when
    let rows = SchedulerHealth.rows(
      SchedulerHealth.Snapshot(
        state: .available(state),
        dueCount: .available(2),
        proactiveTodayUSD: .available(0.42),
        proactivePerDayUSD: 2.0,
        heartbeatEnabled: true,
        heartbeatMaxPerDay: 8,
        timezone: berlin,
        now: now
      )
    )

    // then
    #expect(
      value(rows, "scheduler.last_tick_at") == String(describing: now.addingTimeInterval(-60))
    )
    #expect(value(rows, "scheduler.due_count") == "2")
    #expect(value(rows, "scheduler.last_misfire")?.contains("skipped 5") == true)
    #expect(value(rows, "spend.proactive_today_usd") == "0.42/2.00")
    #expect(value(rows, "heartbeat.enabled") == "on")
    #expect(value(rows, "heartbeat.today") == "3/8")
  }

  @Test func staleHeartbeatDayStampReadsAsZero() {
    // given — the counter belongs to a PREVIOUS local day: the cap has rolled over (§4.3)
    let state = SchedulerState(
      lastTickAt: nil,
      lastMisfireAt: nil,
      lastMisfireSkippedCount: 0,
      lastHeartbeatAt: nil,
      heartbeatCountDay: "2026-07-05",
      heartbeatCount: 7
    )

    // when
    let rows = SchedulerHealth.rows(
      SchedulerHealth.Snapshot(
        state: .available(state),
        dueCount: .unavailable,
        proactiveTodayUSD: .unavailable,
        proactivePerDayUSD: 2.0,
        heartbeatEnabled: true,
        heartbeatMaxPerDay: 8,
        timezone: berlin,
        now: now
      )
    )

    // then — a stale stamp reads as zero; failed queries fail their rows instead of lying
    #expect(value(rows, "heartbeat.today") == "0/8")
    #expect(value(rows, "scheduler.due_count") == "unreadable (db read failed)")
    #expect(value(rows, "spend.proactive_today_usd") == "unreadable (db read failed)")
    #expect(rows.first { $0.key == "scheduler.due_count" }?.ok == false)
    #expect(rows.first { $0.key == "spend.proactive_today_usd" }?.ok == false)
  }

  @Test func dayBoundaryUsesTheConfiguredZoneNotUTC() {
    // given — 2026-07-06 23:30 UTC is already 2026-07-07 01:30 in Berlin (CEST, UTC+2)
    let lateEvening = Date(timeIntervalSince1970: 1_783_380_600)
    let state = SchedulerState(
      lastTickAt: nil,
      lastMisfireAt: nil,
      lastMisfireSkippedCount: 0,
      lastHeartbeatAt: nil,
      heartbeatCountDay: "2026-07-07",
      heartbeatCount: 2
    )

    // when
    let rows = SchedulerHealth.rows(
      SchedulerHealth.Snapshot(
        state: .available(state),
        dueCount: .available(0),
        proactiveTodayUSD: .available(0),
        proactivePerDayUSD: 2.0,
        heartbeatEnabled: true,
        heartbeatMaxPerDay: 8,
        timezone: berlin,
        now: lateEvening
      )
    )

    // then — the cap's day boundary aligns with quiet hours (CLAW_TIMEZONE), not UTC (§4.3)
    #expect(value(rows, "heartbeat.today") == "2/8")
  }
}
