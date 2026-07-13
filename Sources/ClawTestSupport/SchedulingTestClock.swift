import Foundation

/// The two fixed, DST-free instants every scheduling suite pins its expectations to. Sharing them
/// keeps the epoch literals, and the wall-clock meaning documented here, in exactly one place — so
/// a drift in one suite can never silently disagree with another.
public enum SchedulingTestClock {
  /// Monday 2026-07-06 12:00:00 UTC == 14:00 Europe/Berlin (CEST). The canonical "arm"/"now"
  /// anchor: mid-afternoon local, well clear of any DST edge.
  public static let mondayNoonBerlin = Date(timeIntervalSince1970: 1_783_339_200)

  /// Tuesday 2026-07-07 07:00 Europe/Berlin == 05:00 UTC — the next weekday/daily-07:00 fire that
  /// follows `mondayNoonBerlin`.
  public static let tuesdaySevenBerlin = Date(timeIntervalSince1970: 1_783_400_400)
}
