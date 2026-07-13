import Foundation

extension Date {
  public var startOfUTCDay: Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar.startOfDay(for: self)
  }

  /// `YYYY-MM-DD` wall-clock day in `zone`, fixed-width and locale-free. This is the persisted
  /// `scheduler_state.heartbeat_count_day` stamp format — the padding must stay byte-for-byte
  /// stable so a stored stamp keeps comparing equal to a freshly rendered one.
  public func wallClockDay(in zone: TimeZone) -> String {
    let parts = components([.year, .month, .day], in: zone)
    return String(
      format: "%04d-%02d-%02d",
      parts.year ?? 0,
      parts.month ?? 0,
      parts.day ?? 0
    )
  }

  /// `YYYY-MM-DD HH:mm` wall-clock minute in `zone` — deterministic and locale-free (the ISO8601
  /// format styles force seconds; schedules are owner-authored in whole minutes).
  public func wallClockMinute(in zone: TimeZone) -> String {
    let parts = components([.year, .month, .day, .hour, .minute], in: zone)
    return String(
      format: "%04d-%02d-%02d %02d:%02d",
      parts.year ?? 0,
      parts.month ?? 0,
      parts.day ?? 0,
      parts.hour ?? 0,
      parts.minute ?? 0
    )
  }
}

// MARK: - Calendar Components

private extension Date {
  /// A fresh value-type gregorian calendar per call keeps this `Sendable` without a shared
  /// formatter; `Calendar`/`TimeZone` are cheap value types.
  func components(_ units: Set<Calendar.Component>, in zone: TimeZone) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.dateComponents(units, from: self)
  }
}
