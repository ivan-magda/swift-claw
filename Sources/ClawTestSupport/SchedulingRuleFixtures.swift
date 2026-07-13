import ClawCore
import Foundation

/// Parameterized `Calendar.RecurrenceRule` builders shared by the scheduling suites. Each suite
/// pins its own zone and (where it matters) `seconds`, so the builders take those as arguments
/// rather than baking in one canonical rule — the recurrence-shaping logic lives here once while
/// callers keep their exact, behavior-defining inputs.
public enum SchedulingRuleFixtures {
  /// A gregorian calendar fixed to `zone`. The recurrence math installs the job's zone itself, so
  /// the calendar's zone is what pins each rule's wall-clock frame.
  public static func calendar(zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }

  /// A gregorian calendar fixed to Europe/Berlin.
  public static func berlinCalendar() -> Calendar {
    calendar(zone: TimeZone(identifier: "Europe/Berlin") ?? .gmt)
  }

  /// Weekly at 07:00, Monday through Friday, in `zone`. `seconds` is empty by default; suites that
  /// need the stored encoding to carry an explicit `:00` pass `[0]`.
  public static func weekdaySeven(zone: TimeZone, seconds: [Int] = []) -> Calendar.RecurrenceRule {
    Calendar.RecurrenceRule(
      calendar: calendar(zone: zone),
      frequency: .weekly,
      weekdays: [
        .every(.monday), .every(.tuesday), .every(.wednesday), .every(.thursday), .every(.friday),
      ],
      hours: [7],
      minutes: [0],
      seconds: seconds
    )
  }

  /// Daily at `hour:minute` in `zone`. `seconds` is empty by default (see `weekdaySeven`).
  public static func dailyAt(
    hour: Int,
    minute: Int,
    zone: TimeZone,
    seconds: [Int] = []
  ) -> Calendar.RecurrenceRule {
    Calendar.RecurrenceRule(
      calendar: calendar(zone: zone),
      frequency: .daily,
      hours: [hour],
      minutes: [minute],
      seconds: seconds
    )
  }

  /// Every `minutes` minutes in `zone`; occurrences recur at anchor + k·(minutes·60 s).
  public static func everyNMinutes(_ minutes: Int, zone: TimeZone) -> Calendar.RecurrenceRule {
    Calendar.RecurrenceRule(calendar: calendar(zone: zone), frequency: .minutely, interval: minutes)
  }

  /// The `weekdaySeven` rule wrapped in the pinned storage envelope, for store round-trip suites.
  public static func weekdayEnvelope(zone: TimeZone, seconds: [Int] = []) -> RecurrenceEnvelope {
    RecurrenceEnvelope(
      schemaVersion: RecurrenceEnvelope.currentSchemaVersion,
      rule: weekdaySeven(zone: zone, seconds: seconds)
    )
  }
}
