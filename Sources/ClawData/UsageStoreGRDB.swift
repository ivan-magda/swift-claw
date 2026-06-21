import ClawCore
import Foundation
import GRDB

public struct UsageStoreGRDB: UsageStore {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func recordUsage(_ usage: ProviderUsage) throws {
    try writer.write { db in
      try RunStoreGRDB.insertUsage(db, usage)
    }
  }

  public func todayTokensAndCost(now: Date) throws -> (tokens: Int, costUSD: Double) {
    let dayStart = Self.startOfUTCDay(now)
    return try writer.read { db in
      // GRDB stores Date as a UTC "yyyy-MM-dd HH:mm:ss.SSS" string, so `ts >= ?` is a correct
      // chronological range scan over the calendar-day-UTC window.
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT COALESCE(SUM(prompt_tokens + completion_tokens), 0) AS tokens,
                 COALESCE(SUM(cost_usd), 0) AS cost
          FROM provider_usage WHERE ts >= ?
          """,
        arguments: [dayStart]
      )

      guard let row else {
        return (0, 0)
      }

      return (row["tokens"], row["cost"])
    }
  }

  static func startOfUTCDay(_ now: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar.startOfDay(for: now)
  }
}
