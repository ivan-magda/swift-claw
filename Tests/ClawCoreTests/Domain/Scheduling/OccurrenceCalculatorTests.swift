import Foundation
import Testing

@testable import ClawCore

@Suite struct OccurrenceCalculatorTests {
  private let calculator = OccurrenceCalculator()
  private let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt
  private let utcZone = TimeZone.gmt

  private func utcDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int
  ) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcZone
    let components = DateComponents(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute
    )
    guard let date = calendar.date(from: components) else {
      Issue.record("bad fixture: \(components)")
      return Date(timeIntervalSince1970: 0)
    }
    return date
  }

  /// Rules are deliberately built on a UTC calendar: the calculator must install the job's
  /// zone itself (the IANA zone is a separate column rebuilt on load — spec D2).
  private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcZone
    return calendar
  }

  private func weekdaySevenRule() -> Calendar.RecurrenceRule {
    Calendar.RecurrenceRule(
      calendar: utcCalendar(),
      frequency: .weekly,
      weekdays: [
        .every(.monday), .every(.tuesday), .every(.wednesday), .every(.thursday), .every(.friday),
      ],
      hours: [7],
      minutes: [0]
    )
  }

  private func dailyTwoThirtyRule() -> Calendar.RecurrenceRule {
    Calendar.RecurrenceRule(
      calendar: utcCalendar(),
      frequency: .daily,
      hours: [2],
      minutes: [30]
    )
  }

  private func everyThirtyMinutesRule() -> Calendar.RecurrenceRule {
    Calendar.RecurrenceRule(calendar: utcCalendar(), frequency: .minutely, interval: 30)
  }

  private func berlinHourMinute(of date: Date) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = berlin
    return calendar.dateComponents([.hour, .minute], from: date)
  }

  @Test func weekdaySevenStaysAtLocalSevenAcrossSpringForward() {
    // given — anchored Thu 2026-03-26 12:00Z; Europe/Berlin springs forward Sun 2026-03-29
    let anchor = utcDate(2026, 3, 26, 12, 0)

    // when
    let occurrences = calculator.occurrences(
      rule: weekdaySevenRule(),
      timezone: berlin,
      anchor: anchor,
      after: anchor,
      limit: 3
    )

    // then — the UTC instant shifts 06:00Z → 05:00Z; the Berlin wall clock does not move (SC7)
    #expect(
      occurrences == [
        utcDate(2026, 3, 27, 6, 0),
        utcDate(2026, 3, 30, 5, 0),
        utcDate(2026, 3, 31, 5, 0),
      ]
    )
    for occurrence in occurrences {
      let local = berlinHourMinute(of: occurrence)
      #expect(local.hour == 7)
      #expect(local.minute == 0)
    }
  }

  @Test func weekdaySevenStaysAtLocalSevenAcrossFallBack() {
    // given — anchored Thu 2026-10-22 12:00Z; Europe/Berlin falls back Sun 2026-10-25
    let anchor = utcDate(2026, 10, 22, 12, 0)

    // when
    let occurrences = calculator.occurrences(
      rule: weekdaySevenRule(),
      timezone: berlin,
      anchor: anchor,
      after: anchor,
      limit: 3
    )

    // then — the UTC instant shifts 05:00Z → 06:00Z; local 07:00 on both sides
    #expect(
      occurrences == [
        utcDate(2026, 10, 23, 5, 0),
        utcDate(2026, 10, 26, 6, 0),
        utcDate(2026, 10, 27, 6, 0),
      ]
    )
    for occurrence in occurrences {
      let local = berlinHourMinute(of: occurrence)
      #expect(local.hour == 7)
      #expect(local.minute == 0)
    }
  }

  @Test func nonexistentLocalTimeResolvesForwardAndRecoversNextDay() {
    // given — 02:30 does not exist on 2026-03-29 in Berlin (02:00 jumps to 03:00)
    let anchor = utcDate(2026, 3, 27, 12, 0)

    // when
    let occurrences = calculator.occurrences(
      rule: dailyTwoThirtyRule(),
      timezone: berlin,
      anchor: anchor,
      after: utcDate(2026, 3, 28, 12, 0),
      limit: 2
    )

    // then — resolved to the platform's next valid instant (03:30 local), never dropped
    // (spec §6); the following day is back at the nominal local 02:30
    #expect(occurrences == [utcDate(2026, 3, 29, 1, 30), utcDate(2026, 3, 30, 0, 30)])
    let transitionDayLocal = berlinHourMinute(of: occurrences[0])
    #expect(transitionDayLocal.hour == 3)
    #expect(transitionDayLocal.minute == 30)
    let nextDayLocal = berlinHourMinute(of: occurrences[1])
    #expect(nextDayLocal.hour == 2)
    #expect(nextDayLocal.minute == 30)
  }

  @Test func ambiguousLocalTimeYieldsExactlyOneInstant() {
    // given — 02:30 occurs twice on 2026-10-25 in Berlin (03:00 CEST falls back to 02:00 CET)
    let anchor = utcDate(2026, 10, 23, 12, 0)

    // when
    let occurrences = calculator.occurrences(
      rule: dailyTwoThirtyRule(),
      timezone: berlin,
      anchor: anchor,
      after: utcDate(2026, 10, 24, 12, 0),
      limit: 2
    )

    // then — one resolved UTC instant per local day; the claim keys on it, so one fire (§6)
    #expect(occurrences == [utcDate(2026, 10, 25, 0, 30), utcDate(2026, 10, 26, 1, 30)])
    let berlinDayStart = utcDate(2026, 10, 24, 22, 0)  // local 2026-10-25 00:00 (CEST)
    let berlinDayEnd = utcDate(2026, 10, 25, 23, 0)  // local 2026-10-26 00:00 (CET)
    let onTransitionDay = occurrences.filter { instant in
      instant >= berlinDayStart && instant < berlinDayEnd
    }
    #expect(onTransitionDay.count == 1)
  }

  @Test func everyThirtyMinutesKeepsTheAnchorPhase() {
    // given — anchored at 10:07Z: the phase is :07/:37 forever, whatever the query time
    let anchor = utcDate(2026, 7, 6, 10, 7)

    // when
    let nearQuery = calculator.occurrences(
      rule: everyThirtyMinutesRule(),
      timezone: berlin,
      anchor: anchor,
      after: utcDate(2026, 7, 6, 11, 0),
      limit: 2
    )
    let laterQuery = calculator.occurrences(
      rule: everyThirtyMinutesRule(),
      timezone: berlin,
      anchor: anchor,
      after: utcDate(2026, 7, 6, 12, 0),
      limit: 2
    )

    // then — a stable anchor means the phase can never drift with the query date
    #expect(nearQuery == [utcDate(2026, 7, 6, 11, 7), utcDate(2026, 7, 6, 11, 37)])
    #expect(laterQuery == [utcDate(2026, 7, 6, 12, 7), utcDate(2026, 7, 6, 12, 37)])
  }

  @Test func fractionalSecondAnchorsAreFlooredToWholeSeconds() {
    // given — a parse/arm-time anchor seeded from Date() carries fractional seconds;
    // RecurrenceRule would propagate them into every occurrence, breaking the store's
    // exact integer-epoch CAS (§5.2). The calculator floors the seed.
    let fractional = Date(
      timeIntervalSince1970: utcDate(2026, 7, 6, 10, 7).timeIntervalSince1970 + 0.75
    )

    // when
    let occurrences = calculator.occurrences(
      rule: everyThirtyMinutesRule(),
      timezone: berlin,
      anchor: fractional,
      after: fractional,
      limit: 2
    )

    // then — whole seconds, identical to the whole-second anchor's chain
    #expect(occurrences == [utcDate(2026, 7, 6, 10, 37), utcDate(2026, 7, 6, 11, 7)])
    for occurrence in occurrences {
      #expect(
        occurrence.timeIntervalSince1970 == occurrence.timeIntervalSince1970.rounded(.down)
      )
    }
  }

  @Test func occurrencesAreStrictlyAfterTheQueryInstant() {
    // given — recurrences(of:) includes the anchor itself; `after` must exclude it
    let anchor = utcDate(2026, 7, 6, 10, 7)

    // when
    let occurrences = calculator.occurrences(
      rule: everyThirtyMinutesRule(),
      timezone: berlin,
      anchor: anchor,
      after: anchor,
      limit: 1
    )

    // then
    #expect(occurrences == [utcDate(2026, 7, 6, 10, 37)])
  }

  @Test func latestOccurrenceCoalescesToTheNewestMissedInstant() {
    // given — five missed 30-minute occurrences: the §5.3 coalesce target is the LATEST one
    let anchor = utcDate(2026, 7, 6, 10, 7)

    // when
    let latest = calculator.latestOccurrence(
      rule: everyThirtyMinutesRule(),
      timezone: berlin,
      anchor: anchor,
      after: utcDate(2026, 7, 6, 10, 10),
      atOrBefore: utcDate(2026, 7, 6, 12, 40)
    )

    // then
    #expect(latest == utcDate(2026, 7, 6, 12, 37))
  }

  @Test func latestOccurrenceIncludesTheBoundaryAndCanBeNil() {
    // given
    let anchor = utcDate(2026, 7, 6, 10, 7)

    // when — the window is (after, atOrBefore]
    let boundary = calculator.latestOccurrence(
      rule: everyThirtyMinutesRule(),
      timezone: berlin,
      anchor: anchor,
      after: utcDate(2026, 7, 6, 10, 10),
      atOrBefore: utcDate(2026, 7, 6, 10, 37)
    )
    let none = calculator.latestOccurrence(
      rule: everyThirtyMinutesRule(),
      timezone: berlin,
      anchor: anchor,
      after: utcDate(2026, 7, 6, 10, 10),
      atOrBefore: utcDate(2026, 7, 6, 10, 30)
    )

    // then
    #expect(boundary == utcDate(2026, 7, 6, 10, 37))
    #expect(none == nil)
  }

  @Test func degenerateInputsAreEmpty() {
    // given
    let anchor = utcDate(2026, 7, 6, 10, 7)

    // when / then — zero limit and an inverted/empty window produce nothing, never hang
    #expect(
      calculator.occurrences(
        rule: everyThirtyMinutesRule(),
        timezone: berlin,
        anchor: anchor,
        after: anchor,
        limit: 0
      ).isEmpty
    )
    #expect(
      calculator.latestOccurrence(
        rule: everyThirtyMinutesRule(),
        timezone: berlin,
        anchor: anchor,
        after: anchor,
        atOrBefore: anchor
      ) == nil
    )
  }
}
