import ClawCore
import Foundation
import GRDB

public struct UsageStoreGRDB: UsageStore {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func recordUsage(_ usage: ProviderUsage) throws {
    try writer.writeMapping { db in
      try RunStoreGRDB.insertUsage(db, usage)
    }
  }

  public func todayTokensAndCost(now: Date) throws -> (tokens: Int, costUSD: Double) {
    let dayStart = now.startOfUTCDay
    return try writer.readMapping { db in
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

  public func costSourceMix(now: Date) throws -> [CostSource: Int] {
    let dayStart = now.startOfUTCDay
    return try writer.readMapping { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT cost_source, COUNT(*) AS n FROM provider_usage WHERE ts >= ?
          GROUP BY cost_source
          """,
        arguments: [dayStart]
      )
      var result: [CostSource: Int] = [:]
      for row in rows {
        let raw: String = row["cost_source"]
        if let source = CostSource(rawValue: raw) {
          result[source] = row["n"]
        }
      }
      return result
    }
  }
}
