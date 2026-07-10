import Foundation

/// A daily suppression window in minutes-of-day, evaluated in a caller-supplied timezone.
/// The window is half-open `[start, end)` and may cross midnight (e.g. 22:00-09:00).
/// `start == end` is rejected at parse: a zero-width window would silently mean "never quiet"
/// or "always quiet" depending on reading — it is a config error instead.
public struct QuietHours: Sendable, Equatable {
  public let startMinuteOfDay: Int
  public let endMinuteOfDay: Int

  public init(startMinuteOfDay: Int, endMinuteOfDay: Int) {
    self.startMinuteOfDay = startMinuteOfDay
    self.endMinuteOfDay = endMinuteOfDay
  }

  /// Parses `"HH:MM-HH:MM"`; nil on malformed input or a zero-width window.
  public static func parse(_ raw: String) -> QuietHours? {
    let parts = raw.split(separator: "-", omittingEmptySubsequences: false)

    guard
      parts.count == 2,
      let start = minuteOfDay(String(parts[0])),
      let end = minuteOfDay(String(parts[1])),
      start != end
    else {
      return nil
    }

    return QuietHours(startMinuteOfDay: start, endMinuteOfDay: end)
  }

  public func contains(_ instant: Date, timezone: TimeZone) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone

    let components = calendar.dateComponents([.hour, .minute], from: instant)
    let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)

    if startMinuteOfDay < endMinuteOfDay {
      return minute >= startMinuteOfDay && minute < endMinuteOfDay
    }
    // Midnight-crossing window: quiet from start until midnight, then until end.
    return minute >= startMinuteOfDay || minute < endMinuteOfDay
  }

  public var rendered: String {
    String(
      format: "%02d:%02d-%02d:%02d",
      startMinuteOfDay / 60,
      startMinuteOfDay % 60,
      endMinuteOfDay / 60,
      endMinuteOfDay % 60
    )
  }

  private static func minuteOfDay(_ text: String) -> Int? {
    // Fail-closed HH:MM grammar: exactly two ASCII digits per field. "9:00",
    // "09:0", and "+09:00" are config ERRORS — `Int(_:)` alone would accept all three.
    let pieces = text.split(separator: ":", omittingEmptySubsequences: false)

    guard
      pieces.count == 2,
      pieces[0].count == 2,
      pieces[1].count == 2,
      pieces.allSatisfy({ piece in piece.allSatisfy { char in char.isASCII && char.isNumber } }),
      let hour = Int(pieces[0]),
      let minute = Int(pieces[1]),
      (0...23).contains(hour),
      (0...59).contains(minute)
    else {
      return nil
    }

    return hour * 60 + minute
  }
}
