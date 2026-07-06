import Foundation
import Testing

@testable import ClawCore

@Suite struct QuietHoursTests {
  private let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt

  /// A fixed instant at the given Berlin wall-clock time on 2026-07-06 (no DST edge — QuietHours
  /// is a pure minute-of-day window; DST behavior belongs to OccurrenceCalculator).
  private func berlinInstant(hour: Int, minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = berlin
    let components = DateComponents(year: 2026, month: 7, day: 6, hour: hour, minute: minute)
    guard let date = calendar.date(from: components) else {
      Issue.record("bad fixture: \(components)")
      return Date(timeIntervalSince1970: 0)
    }
    return date
  }

  @Test func parsesTheDefaultWindow() throws {
    // given / when
    let window = try #require(QuietHours.parse("22:00-09:00"))

    // then
    #expect(window.startMinuteOfDay == 22 * 60)
    #expect(window.endMinuteOfDay == 9 * 60)
    #expect(window.rendered == "22:00-09:00")
  }

  @Test(arguments: [
    "22:00",  // no end
    "2200-0900",  // no colons
    "24:00-09:00",  // hour out of range
    "22:60-09:00",  // minute out of range
    "22:00-09:00-10:00",  // extra segment
    "aa:bb-cc:dd",  // garbage
    "",  // empty
    "22:00-22:00",  // zero-width window — a config ERROR, never always-skip (spec §12)
    "9:00-17:00",  // one-digit hour — HH:MM means exactly two digits (fail-closed, spec §13)
    "09:0-17:00",  // one-digit minute
    "+09:00-17:00",  // sign prefix — Int(_:) alone would accept it
  ])
  func rejectsMalformedAndZeroWidthWindows(_ raw: String) {
    // given / when / then
    #expect(QuietHours.parse(raw) == nil)
  }

  @Test func midnightCrossingWindowContainsNightAndExcludesDay() throws {
    // given — the default 22:00-09:00 window crosses midnight
    let window = try #require(QuietHours.parse("22:00-09:00"))

    // when / then — [start, end): 22:00 is quiet, 09:00 is not
    #expect(window.contains(berlinInstant(hour: 23, minute: 30), timezone: berlin))
    #expect(window.contains(berlinInstant(hour: 3, minute: 0), timezone: berlin))
    #expect(window.contains(berlinInstant(hour: 22, minute: 0), timezone: berlin))
    #expect(window.contains(berlinInstant(hour: 8, minute: 59), timezone: berlin))
    #expect(window.contains(berlinInstant(hour: 9, minute: 0), timezone: berlin) == false)
    #expect(window.contains(berlinInstant(hour: 12, minute: 0), timezone: berlin) == false)
    #expect(window.contains(berlinInstant(hour: 21, minute: 59), timezone: berlin) == false)
  }

  @Test func sameDayWindowIsAPlainInterval() throws {
    // given
    let window = try #require(QuietHours.parse("09:00-17:00"))

    // when / then
    #expect(window.contains(berlinInstant(hour: 12, minute: 0), timezone: berlin))
    #expect(window.contains(berlinInstant(hour: 9, minute: 0), timezone: berlin))
    #expect(window.contains(berlinInstant(hour: 17, minute: 0), timezone: berlin) == false)
    #expect(window.contains(berlinInstant(hour: 8, minute: 59), timezone: berlin) == false)
    #expect(window.contains(berlinInstant(hour: 23, minute: 0), timezone: berlin) == false)
  }

  @Test func containsEvaluatesInTheGivenTimezone() throws {
    // given — 23:00 Berlin is 21:00 UTC; the same instant must classify differently per zone
    let window = try #require(QuietHours.parse("22:00-09:00"))
    let instant = berlinInstant(hour: 23, minute: 0)

    // when / then
    #expect(window.contains(instant, timezone: berlin))
    #expect(window.contains(instant, timezone: TimeZone(identifier: "UTC") ?? .gmt) == false)
  }
}
