import Foundation

/// The single home of occurrence math over `Calendar.RecurrenceRule` (spec §6): the ticker,
/// the confirm prompt's next-3 preview, and `/schedule list` all consult this type, so they can
/// never disagree.
///
/// DST policy (pinned, spec §6): a nonexistent local time resolves to the platform's next valid
/// instant, never dropped; an ambiguous local time yields exactly one resolved UTC instant (the
/// claim is keyed on it, so it fires once); wall-clock rules stay at local time across
/// transitions. All three behaviors are pinned by `OccurrenceCalculatorTests`.
public struct OccurrenceCalculator: Sendable {
  public init() {}

  /// Occurrences strictly after `after`, ascending. `anchor` seeds `rule.recurrences(of:)` —
  /// pass the occurrence-chain seed: the occurrence being advanced from (the claimed `due` at
  /// tick advance; validation `now` at parse/arm; the stale stored next at resume). It pins the
  /// phase of everyNMinutes rules and is inert for rules that pin hour/minute/weekday (preamble
  /// deviation 1). `recurrences(of:)` yields the anchor itself when it matches, which the
  /// strict `after` bound excludes.
  public func occurrences(
    rule: Calendar.RecurrenceRule,
    timezone: TimeZone,
    anchor: Date,
    after: Date,
    limit: Int
  ) -> [Date] {
    guard limit > 0 else {
      return []
    }

    let localized = Self.installing(timezone, on: rule)
    var found: [Date] = []
    // The sequence is ascending, so the loop terminates at `limit` (or at the rule's end).
    for occurrence in localized.recurrences(of: Self.wholeSecond(anchor)) {
      guard occurrence > after else {
        continue
      }
      found.append(occurrence)
      if found.count == limit {
        break
      }
    }
    return found
  }

  /// Latest occurrence in `(after, atOrBefore]` — the §5.3 coalesce target. nil when none.
  public func latestOccurrence(
    rule: Calendar.RecurrenceRule,
    timezone: TimeZone,
    anchor: Date,
    after: Date,
    atOrBefore: Date
  ) -> Date? {
    guard atOrBefore > after else {
      return nil
    }

    let localized = Self.installing(timezone, on: rule)
    var latest: Date?
    for occurrence in localized.recurrences(of: Self.wholeSecond(anchor)) {
      if occurrence > atOrBefore {
        break  // ascending: nothing later can qualify
      }
      if occurrence > after {
        latest = occurrence
      }
    }
    return latest
  }

  /// `RecurrenceRule` propagates the seed's fractional seconds into every occurrence
  /// (verified on this toolchain), and parse/arm-time anchors come from `Date()`. Flooring
  /// the seed keeps every emitted occurrence a whole second — the store persists integer
  /// epochs and the fused claim compares exact integers (§5.2).
  private static func wholeSecond(_ instant: Date) -> Date {
    Date(timeIntervalSince1970: instant.timeIntervalSince1970.rounded(.down))
  }

  /// The job's IANA zone lives in its own column (spec D2); installing it on the rule's
  /// calendar here is what makes the rule's wall-clock components mean "local time in the
  /// job's zone", wherever the rule was built.
  private static func installing(
    _ timezone: TimeZone,
    on rule: Calendar.RecurrenceRule
  ) -> Calendar.RecurrenceRule {
    var localized = rule
    var calendar = localized.calendar
    calendar.timeZone = timezone
    localized.calendar = calendar
    return localized
  }
}
