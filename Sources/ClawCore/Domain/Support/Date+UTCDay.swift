import Foundation

extension Date {
  public var startOfUTCDay: Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar.startOfDay(for: self)
  }
}
