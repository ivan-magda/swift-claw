import Foundation

// MARK: - The §7 draft DSL (Codable mirror of the model's JSON)

/// The constrained draft the parse LLM must emit (spec §7). Never stored: code validates it and
/// code constructs the stored rule (D2/D11) — the model never authors a `RecurrenceRule`.
public struct ScheduleDraft: Sendable, Equatable, Codable {
  public let label: String
  public let prompt: String
  public let schedule: DraftSchedule

  public init(label: String, prompt: String, schedule: DraftSchedule) {
    self.label = label
    self.prompt = prompt
    self.schedule = schedule
  }
}

public struct DraftSchedule: Sendable, Equatable, Codable {
  public let kind: DraftScheduleKind
  public let time: String?
  public let weekday: String?
  public let date: String?
  public let intervalMinutes: Int?
  public let timezone: String?

  public init(
    kind: DraftScheduleKind,
    time: String? = nil,
    weekday: String? = nil,
    date: String? = nil,
    intervalMinutes: Int? = nil,
    timezone: String? = nil
  ) {
    self.kind = kind
    self.time = time
    self.weekday = weekday
    self.date = date
    self.intervalMinutes = intervalMinutes
    self.timezone = timezone
  }
}

public enum DraftScheduleKind: String, Sendable, Equatable, Codable {
  case once
  case daily
  case weekdays
  case weekly
  case everyNMinutes
}

// MARK: - Validation output

/// Deterministic validation output (spec §7): the exact thing parked, displayed, and armed. The
/// arm commit inserts FROM this value, never a re-parse (kills the display/arm TOCTOU, §8).
public struct ValidatedSchedule: Sendable, Equatable {
  public let label: String
  public let prompt: String
  public let recurrence: RecurrenceEnvelope?
  public let timezone: String
  public let firstOccurrence: Date
  public let recurrenceInWords: String

  public init(
    label: String,
    prompt: String,
    recurrence: RecurrenceEnvelope?,
    timezone: String,
    firstOccurrence: Date,
    recurrenceInWords: String
  ) {
    self.label = label
    self.prompt = prompt
    self.recurrence = recurrence
    self.timezone = timezone
    self.firstOccurrence = firstOccurrence
    self.recurrenceInWords = recurrenceInWords
  }
}

/// Every way a draft can fail deterministic validation (spec §7). Each case carries the
/// plain-language owner reply WITH an example rephrase — the reply is part of the §7 contract,
/// so it lives on the type and is tested, never improvised at a call site.
public enum ScheduleDraftProblem: Error, Sendable, Equatable {
  case emptyLabel
  case labelTooLong(count: Int)
  case emptyPrompt
  case unknownTimezone(String)
  case missingField(kind: DraftScheduleKind, field: String)
  case invalidTime(String)
  case invalidDate(String)
  case invalidWeekday(String)
  case intervalTooSmall(minutes: Int, floorMinutes: Int)
  case onceInThePast
  case noUpcomingOccurrence

  public var ownerReply: String {
    let example = "Example: /schedule every weekday at 07:00 — summarize my unread items"
    switch self {
    case .emptyLabel:
      return """
        I need a short name for this schedule. \(example)
        """
    case .labelTooLong(let count):
      return """
        That label is \(count) characters — the cap is 64. Use a shorter name. \(example)
        """
    case .emptyPrompt:
      return """
        I need a task to run. \(example)
        """
    case .unknownTimezone(let zone):
      return """
        I don't recognize the timezone «\(zone)». Use an IANA name like Europe/Berlin. \
        \(example)
        """
    case .missingField(let kind, let field):
      return """
        A \(kind.rawValue) schedule needs «\(field)». \(example)
        """
    case .invalidTime(let time):
      return """
        «\(time)» isn't a time I can use — write 24-hour HH:MM. \
        Example: /schedule every day at 07:30 — summarize my unread items
        """
    case .invalidDate(let date):
      return """
        «\(date)» isn't a date I can use — write YYYY-MM-DD. \
        Example: /schedule once on 2026-07-10 at 09:00 — send the report reminder
        """
    case .invalidWeekday(let day):
      return """
        «\(day)» isn't a weekday I know — use monday…sunday. \
        Example: /schedule every friday at 16:00 — post the weekly summary
        """
    case .intervalTooSmall(let minutes, let floorMinutes):
      return """
        Every \(minutes) minutes is below the \(floorMinutes)-minute floor. \
        Example: /schedule every 30 minutes — check the build status
        """
    case .onceInThePast:
      return """
        That time is already in the past. Pick a future one. \
        Example: /schedule once on 2026-07-10 at 09:00 — send the report reminder
        """
    case .noUpcomingOccurrence:
      return """
        I couldn't find an upcoming time for that schedule. \(example)
        """
    }
  }
}

// MARK: - Recurrence in words

/// The single recurrence-in-words renderer. Derives ONLY from the stored rule, so the confirm
/// prompt (validation time) and `/schedule list` (load time) can never describe one job
/// differently.
public enum RecurrenceWords {
  public static func describe(_ recurrence: RecurrenceEnvelope?) -> String {
    guard let recurrence else {
      return "once"
    }

    let rule = recurrence.rule
    switch rule.frequency {
    case .minutely:
      return "every \(rule.interval) minutes"
    case .daily:
      return "every day at \(clock(rule))"
    case .weekly:
      return weeklyWords(rule)
    default:
      // Unreachable for rules this validator builds; a future rule shape degrades readably.
      return "custom schedule"
    }
  }

  private static func weeklyWords(_ rule: Calendar.RecurrenceRule) -> String {
    let days = rule.weekdays.compactMap { weekday -> Locale.Weekday? in
      if case .every(let day) = weekday {
        return day
      }
      return nil
    }

    if days.count == 5, Set(days) == [.monday, .tuesday, .wednesday, .thursday, .friday] {
      return "every weekday at \(clock(rule))"
    }

    guard days.isEmpty == false else {
      return "custom schedule"
    }

    let names = days.map { day in fullName(day) }.joined(separator: ", ")
    return "every \(names) at \(clock(rule))"
  }

  private static func clock(_ rule: Calendar.RecurrenceRule) -> String {
    String(format: "%02d:%02d", rule.hours.first ?? 0, rule.minutes.first ?? 0)
  }

  private static func fullName(_ day: Locale.Weekday) -> String {
    switch day {
    case .sunday: "sunday"
    case .monday: "monday"
    case .tuesday: "tuesday"
    case .wednesday: "wednesday"
    case .thursday: "thursday"
    case .friday: "friday"
    case .saturday: "saturday"
    @unknown default: "weekday"
    }
  }
}

// MARK: - Validator

/// Deterministic §7 validation plus the ONLY draft → `Calendar.RecurrenceRule` mapping
/// (exhaustive switch). Pure: fixed inputs and an injected `now` produce a fixed
/// `ValidatedSchedule`; the calculator is the same one the ticker uses, so the previewed first
/// fire and the armed `next_occurrence` agree by construction.
public struct ScheduleDraftValidator: Sendable {
  public static let maxLabelGraphemes = 64

  public let minIntervalMinutes: Int
  public let defaultTimezone: TimeZone

  private let calculator = OccurrenceCalculator()

  public init(minIntervalMinutes: Int, defaultTimezone: TimeZone) {
    self.minIntervalMinutes = minIntervalMinutes
    self.defaultTimezone = defaultTimezone
  }

  public func validate(
    _ draft: ScheduleDraft,
    now: Date
  ) -> Result<ValidatedSchedule, ScheduleDraftProblem> {
    let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard label.isEmpty == false else {
      return .failure(.emptyLabel)
    }

    guard label.count <= Self.maxLabelGraphemes else {
      return .failure(.labelTooLong(count: label.count))
    }

    let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard prompt.isEmpty == false else {
      return .failure(.emptyPrompt)
    }

    let timezone: TimeZone
    if let rawTimezone = draft.schedule.timezone {
      guard let resolved = TimeZone(identifier: rawTimezone) else {
        return .failure(.unknownTimezone(rawTimezone))
      }
      timezone = resolved
    } else {
      timezone = defaultTimezone
    }

    switch draft.schedule.kind {
    case .once:
      return onceSchedule(
        draft.schedule,
        label: label,
        prompt: prompt,
        timezone: timezone,
        now: now
      )
    case .daily, .weekdays, .weekly, .everyNMinutes:
      return recurringSchedule(
        draft.schedule,
        label: label,
        prompt: prompt,
        timezone: timezone,
        now: now
      )
    }
  }

  // MARK: - Recurring kinds

  private func recurringSchedule(
    _ schedule: DraftSchedule,
    label: String,
    prompt: String,
    timezone: TimeZone,
    now: Date
  ) -> Result<ValidatedSchedule, ScheduleDraftProblem> {
    switch buildRule(schedule, timezone: timezone) {
    case .failure(let problem):
      return .failure(problem)
    case .success(let rule):
      // anchor = now: pre-arm there is no createdTs. The parked firstOccurrence is what arms
      // (it becomes the stored next_occurrence), so the preview's first fire and the armed
      // first fire are the same value by construction.
      guard
        let first = calculator.occurrences(
          rule: rule,
          timezone: timezone,
          anchor: now,
          after: now,
          limit: 1
        ).first
      else {
        return .failure(.noUpcomingOccurrence)
      }

      let envelope = RecurrenceEnvelope(schemaVersion: 1, rule: rule)

      return .success(
        ValidatedSchedule(
          label: label,
          prompt: prompt,
          recurrence: envelope,
          timezone: timezone.identifier,
          firstOccurrence: first,
          recurrenceInWords: RecurrenceWords.describe(envelope)
        )
      )
    }
  }

  /// The exhaustive draft → rule mapping (spec §7). Every rule pins `seconds: [0]` so fires
  /// land on the minute regardless of when validation ran.
  private func buildRule(
    _ schedule: DraftSchedule,
    timezone: TimeZone
  ) -> Result<Calendar.RecurrenceRule, ScheduleDraftProblem> {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone

    switch schedule.kind {
    case .once:
      preconditionFailure("once has no rule; onceSchedule handles it")
    case .everyNMinutes:
      guard let interval = schedule.intervalMinutes else {
        return .failure(.missingField(kind: .everyNMinutes, field: "intervalMinutes"))
      }

      guard interval >= minIntervalMinutes else {
        return .failure(
          .intervalTooSmall(minutes: interval, floorMinutes: minIntervalMinutes)
        )
      }

      return .success(
        Calendar.RecurrenceRule(
          calendar: calendar,
          frequency: .minutely,
          interval: interval,
          seconds: [0]
        )
      )
    case .daily:
      return clockComponents(schedule, kind: .daily).map { clock in
        Calendar.RecurrenceRule(
          calendar: calendar,
          frequency: .daily,
          hours: [clock.hour],
          minutes: [clock.minute],
          seconds: [0]
        )
      }
    case .weekdays:
      return clockComponents(schedule, kind: .weekdays).map { clock in
        Calendar.RecurrenceRule(
          calendar: calendar,
          frequency: .weekly,
          weekdays: [
            .every(.monday), .every(.tuesday), .every(.wednesday), .every(.thursday),
            .every(.friday),
          ],
          hours: [clock.hour],
          minutes: [clock.minute],
          seconds: [0]
        )
      }
    case .weekly:
      guard let rawWeekday = schedule.weekday else {
        return .failure(.missingField(kind: .weekly, field: "weekday"))
      }

      guard let weekday = Self.weekday(named: rawWeekday) else {
        return .failure(.invalidWeekday(rawWeekday))
      }

      return clockComponents(schedule, kind: .weekly).map { clock in
        Calendar.RecurrenceRule(
          calendar: calendar,
          frequency: .weekly,
          weekdays: [.every(weekday)],
          hours: [clock.hour],
          minutes: [clock.minute],
          seconds: [0]
        )
      }
    }
  }

  // MARK: - Once

  private func onceSchedule(
    _ schedule: DraftSchedule,
    label: String,
    prompt: String,
    timezone: TimeZone,
    now: Date
  ) -> Result<ValidatedSchedule, ScheduleDraftProblem> {
    guard let rawTime = schedule.time else {
      return .failure(.missingField(kind: .once, field: "time"))
    }
    guard let clock = Self.parseClock(rawTime) else {
      return .failure(.invalidTime(rawTime))
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone

    let resolved: Date
    if let rawDate = schedule.date {
      guard let dayParts = Self.parseDay(rawDate) else {
        return .failure(.invalidDate(rawDate))
      }

      var parts = DateComponents()
      parts.year = dayParts.year
      parts.month = dayParts.month
      parts.day = dayParts.day
      parts.hour = clock.hour
      parts.minute = clock.minute
      parts.second = 0
      // date(from:) silently normalizes overflow (2026-02-31 → March); the round-trip check
      // rejects that instead of arming a surprise date.
      guard
        let instant = calendar.date(from: parts),
        Self.dayRoundTrips(parts, instant: instant, calendar: calendar)
      else {
        return .failure(.invalidDate(rawDate))
      }

      resolved = instant
    } else {
      // Omitted date ⇒ the next instant matching HH:MM in the zone (spec §7).
      var match = DateComponents()
      match.hour = clock.hour
      match.minute = clock.minute
      match.second = 0

      guard
        let instant = calendar.nextDate(
          after: now,
          matching: match,
          matchingPolicy: .nextTime
        )
      else {
        return .failure(.noUpcomingOccurrence)
      }

      resolved = instant
    }

    guard resolved > now else {
      return .failure(.onceInThePast)
    }

    return .success(
      ValidatedSchedule(
        label: label,
        prompt: prompt,
        recurrence: nil,
        timezone: timezone.identifier,
        firstOccurrence: resolved,
        recurrenceInWords: RecurrenceWords.describe(nil)
      )
    )
  }

  // MARK: - Field parsers

  private func clockComponents(
    _ schedule: DraftSchedule,
    kind: DraftScheduleKind
  ) -> Result<(hour: Int, minute: Int), ScheduleDraftProblem> {
    guard let rawTime = schedule.time else {
      return .failure(.missingField(kind: kind, field: "time"))
    }

    guard let clock = Self.parseClock(rawTime) else {
      return .failure(.invalidTime(rawTime))
    }

    return .success(clock)
  }

  static func parseClock(_ text: String) -> (hour: Int, minute: Int)? {
    let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
    guard
      pieces.count == 2,
      let hour = Int(pieces[0]),
      let minute = Int(pieces[1]),
      (0...23).contains(hour),
      (0...59).contains(minute)
    else {
      return nil
    }
    return (hour, minute)
  }

  static func parseDay(_ text: String) -> (year: Int, month: Int, day: Int)? {
    let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
    guard
      pieces.count == 3,
      let year = Int(pieces[0]),
      let month = Int(pieces[1]),
      let day = Int(pieces[2]),
      (1...12).contains(month),
      (1...31).contains(day)
    else {
      return nil
    }
    return (year, month, day)
  }

  private static func dayRoundTrips(
    _ parts: DateComponents,
    instant: Date,
    calendar: Calendar
  ) -> Bool {
    let back = calendar.dateComponents([.year, .month, .day], from: instant)
    return back.year == parts.year && back.month == parts.month && back.day == parts.day
  }

  static func weekday(named raw: String) -> Locale.Weekday? {
    switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
    case "monday", "mon": .monday
    case "tuesday", "tue": .tuesday
    case "wednesday", "wed": .wednesday
    case "thursday", "thu": .thursday
    case "friday", "fri": .friday
    case "saturday", "sat": .saturday
    case "sunday", "sun": .sunday
    default: nil
    }
  }
}
