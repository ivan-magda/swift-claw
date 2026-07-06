import Foundation
import Testing

@testable import ClawCore

@Suite struct ScheduleDraftValidatorTests {
  /// Monday 2026-07-06 12:00:00 UTC == 14:00 Europe/Berlin (CEST). All expectations below are
  /// derived from this fixed instant — no real clocks.
  private let fixedNow = Date(timeIntervalSince1970: 1_783_339_200)

  private func makeValidator() throws -> ScheduleDraftValidator {
    ScheduleDraftValidator(
      minIntervalMinutes: 5,
      defaultTimezone: try #require(TimeZone(identifier: "Europe/Berlin"))
    )
  }

  private func draft(
    label: String = "morning digest",
    prompt: String = "Summarize my unread items",
    kind: DraftScheduleKind,
    time: String? = nil,
    weekday: String? = nil,
    date: String? = nil,
    intervalMinutes: Int? = nil,
    timezone: String? = "Europe/Berlin"
  ) -> ScheduleDraft {
    ScheduleDraft(
      label: label,
      prompt: prompt,
      schedule: DraftSchedule(
        kind: kind,
        time: time,
        weekday: weekday,
        date: date,
        intervalMinutes: intervalMinutes,
        timezone: timezone
      )
    )
  }

  private func berlinParts(_ date: Date) throws -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
    return calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second, .weekday],
      from: date
    )
  }

  @Test func weekdaysDraftValidatesWithRuleWordsAndFirstOccurrence() throws {
    // given — 07:00 already passed today (it is 14:00 local)
    let validator = try makeValidator()
    let weekdayDraft = draft(kind: .weekdays, time: "07:00")

    // when
    let validated = try validator.validate(weekdayDraft, now: fixedNow).get()

    // then — Tuesday 2026-07-07 at LOCAL 07:00, a real rule, the shared words rendering
    #expect(validated.label == "morning digest")
    #expect(validated.prompt == "Summarize my unread items")
    #expect(validated.timezone == "Europe/Berlin")
    #expect(validated.recurrence != nil)
    #expect(validated.recurrenceInWords == "every weekday at 07:00")
    let parts = try berlinParts(validated.firstOccurrence)
    #expect(parts.day == 7)
    #expect(parts.hour == 7)
    #expect(parts.minute == 0)
    #expect(parts.second == 0)
  }

  @Test func defaultTimezoneAppliesWhenDraftOmitsIt() throws {
    // given
    let validator = try makeValidator()
    let dailyDraft = draft(kind: .daily, time: "08:30", timezone: nil)

    // when
    let validated = try validator.validate(dailyDraft, now: fixedNow).get()

    // then — resolved to the injected CLAW_TIMEZONE default; next 08:30 is tomorrow
    #expect(validated.timezone == "Europe/Berlin")
    #expect(validated.recurrenceInWords == "every day at 08:30")
    let parts = try berlinParts(validated.firstOccurrence)
    #expect(parts.day == 7)
    #expect(parts.hour == 8)
    #expect(parts.minute == 30)
  }

  @Test func weeklyDraftPinsTheNamedWeekday() throws {
    // given — today IS Monday, but 09:00 has passed, so the fire is NEXT Monday
    let validator = try makeValidator()
    let weeklyDraft = draft(kind: .weekly, time: "09:00", weekday: "monday")

    // when
    let validated = try validator.validate(weeklyDraft, now: fixedNow).get()

    // then
    #expect(validated.recurrenceInWords == "every monday at 09:00")
    let parts = try berlinParts(validated.firstOccurrence)
    #expect(parts.weekday == 2)  // gregorian Monday
    #expect(parts.day == 13)
    #expect(parts.hour == 9)
  }

  @Test func everyNMinutesKeepsAnchorPhaseAndWords() throws {
    // given
    let validator = try makeValidator()
    let intervalDraft = draft(kind: .everyNMinutes, intervalMinutes: 30)

    // when
    let validated = try validator.validate(intervalDraft, now: fixedNow).get()

    // then — anchored at `now`, first fire is exactly one interval later
    #expect(validated.recurrenceInWords == "every 30 minutes")
    #expect(validated.firstOccurrence == fixedNow.addingTimeInterval(1_800))
  }

  @Test func everyNMinutesValidatedMidMinuteLandsOnWholeMinutes() throws {
    // given — validation at hh:mm:23. The rule pins seconds [0] (the mapping's contract), so
    // fires land on the minute — the owner-facing words render minutes only, and a hidden
    // :23-second phase would make every delivery look 23 seconds late.
    let validator = try makeValidator()
    let intervalDraft = draft(kind: .everyNMinutes, intervalMinutes: 30)
    let midMinute = fixedNow.addingTimeInterval(23)

    // when
    let validated = try validator.validate(intervalDraft, now: midMinute).get()

    // then — the next 30-minute mark from the anchor's minute, at second zero
    #expect(validated.firstOccurrence == fixedNow.addingTimeInterval(1_800))
  }

  @Test func intervalBelowFloorIsRejected() throws {
    // given
    let validator = try makeValidator()
    let tooFast = draft(kind: .everyNMinutes, intervalMinutes: 1)

    // when
    let result = validator.validate(tooFast, now: fixedNow)

    // then
    #expect(result == .failure(.intervalTooSmall(minutes: 1, floorMinutes: 5)))
  }

  @Test func onceWithAbsoluteDateResolvesInTheZone() throws {
    // given — 2026-07-08 07:00 Europe/Berlin == 05:00 UTC
    let validator = try makeValidator()
    let onceDraft = draft(kind: .once, time: "07:00", date: "2026-07-08")

    // when
    let validated = try validator.validate(onceDraft, now: fixedNow).get()

    // then
    #expect(validated.recurrence == nil)
    #expect(validated.recurrenceInWords == "once")
    #expect(validated.firstOccurrence == Date(timeIntervalSince1970: 1_783_486_800))
  }

  @Test func onceWithoutDatePicksTheNextMatchingTime() throws {
    // given — 23:15 tonight is still ahead: 2026-07-06 23:15 Berlin == 21:15 UTC
    let validator = try makeValidator()
    let onceDraft = draft(kind: .once, time: "23:15")

    // when
    let validated = try validator.validate(onceDraft, now: fixedNow).get()

    // then
    #expect(validated.firstOccurrence == Date(timeIntervalSince1970: 1_783_372_500))
  }

  @Test func onceInThePastIsRejected() throws {
    // given
    let validator = try makeValidator()
    let staleDraft = draft(kind: .once, time: "07:00", date: "2026-07-05")

    // when / then
    #expect(validator.validate(staleDraft, now: fixedNow) == .failure(.onceInThePast))
  }

  @Test func labelRulesAreEnforcedInGraphemes() throws {
    // given — 65 DECOMPOSED "é" graphemes (130 scalars): the cap counts graphemes, not scalars
    let validator = try makeValidator()
    let longLabel = String(repeating: "e\u{0301}", count: 65)

    // when / then
    #expect(
      validator.validate(draft(label: "  ", kind: .daily, time: "07:00"), now: fixedNow)
        == .failure(.emptyLabel)
    )
    #expect(
      validator.validate(draft(label: longLabel, kind: .daily, time: "07:00"), now: fixedNow)
        == .failure(.labelTooLong(count: 65))
    )
  }

  @Test func emptyPromptIsRejected() throws {
    // given
    let validator = try makeValidator()
    let promptless = draft(prompt: " ", kind: .daily, time: "07:00")

    // when / then
    #expect(validator.validate(promptless, now: fixedNow) == .failure(.emptyPrompt))
  }

  @Test func unknownTimezoneIsRejected() throws {
    // given
    let validator = try makeValidator()
    let martian = draft(kind: .daily, time: "07:00", timezone: "Mars/Olympus")

    // when / then
    #expect(
      validator.validate(martian, now: fixedNow) == .failure(.unknownTimezone("Mars/Olympus"))
    )
  }

  @Test func missingAndInvalidFieldsAreRejected() throws {
    // given
    let validator = try makeValidator()

    // when / then — one row per §7 deterministic check
    #expect(
      validator.validate(draft(kind: .weekly, time: "09:00"), now: fixedNow)
        == .failure(.missingField(kind: .weekly, field: "weekday"))
    )
    #expect(
      validator.validate(draft(kind: .daily), now: fixedNow)
        == .failure(.missingField(kind: .daily, field: "time"))
    )
    #expect(
      validator.validate(draft(kind: .everyNMinutes), now: fixedNow)
        == .failure(.missingField(kind: .everyNMinutes, field: "intervalMinutes"))
    )
    #expect(
      validator.validate(
        draft(kind: .weekly, time: "09:00", weekday: "funday"),
        now: fixedNow
      ) == .failure(.invalidWeekday("funday"))
    )
    #expect(
      validator.validate(draft(kind: .daily, time: "7 am"), now: fixedNow)
        == .failure(.invalidTime("7 am"))
    )
    #expect(
      validator.validate(
        draft(kind: .once, time: "07:00", date: "2026-02-31"),
        now: fixedNow
      ) == .failure(.invalidDate("2026-02-31"))
    )
  }

  @Test(arguments: [
    ScheduleDraftProblem.emptyLabel,
    .labelTooLong(count: 70),
    .emptyPrompt,
    .unknownTimezone("Mars/Olympus"),
    .missingField(kind: .weekly, field: "weekday"),
    .invalidTime("7 am"),
    .invalidDate("2026-02-31"),
    .invalidWeekday("funday"),
    .intervalTooSmall(minutes: 1, floorMinutes: 5),
    .onceInThePast,
    .noUpcomingOccurrence,
  ])
  func everyProblemReplyContainsAnExampleRephrase(problem: ScheduleDraftProblem) {
    // given / when
    let reply = problem.ownerReply

    // then — plain language plus a concrete /schedule example to retry with (spec §7)
    #expect(reply.isEmpty == false)
    #expect(reply.contains("/schedule"))
  }
}
