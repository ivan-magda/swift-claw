import ClawCore
import Foundation
import GRDB

public struct UsageStoreGRDB: UsageStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func recordUsage(_ usage: ProviderUsage) throws(StoreError) {
    try database.writeMapping { db in
      try RunStoreGRDB.insertUsage(db, usage)
    }
  }

  public func todayTokensAndCost(now: Date) throws(StoreError) -> (tokens: Int, costUSD: Double) {
    let dayStart = now.startOfUTCDay
    return try database.readMapping { db in
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

  public func todayTokensAndCost(
    origins: [RunOrigin],
    now: Date
  ) throws(StoreError) -> (tokens: Int, costUSD: Double) {
    guard origins.isEmpty == false else {
      return (0, 0)
    }

    let dayStart = now.startOfUTCDay

    return try database.readMapping { db in
      // databaseQuestionMarks is GRDB's public helper (GRDB/Utils/Utils.swift), not a
      // project symbol — it renders "?,?,?" for the IN clause.
      let placeholders = databaseQuestionMarks(count: origins.count)
      let arguments = StatementArguments(origins.map(\.rawValue)) + [dayStart]
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT COALESCE(SUM(u.prompt_tokens + u.completion_tokens), 0) AS tokens,
                 COALESCE(SUM(u.cost_usd), 0) AS cost
          FROM provider_usage u
          JOIN runs r ON r.id = u.run_id
          WHERE r.origin IN (\(placeholders)) AND u.ts >= ?
          """,
        arguments: arguments
      )

      guard let row else {
        return (0, 0)
      }

      return (row["tokens"], row["cost"])
    }
  }

  public func costSourceMix(now: Date) throws(StoreError) -> [CostSource: Int] {
    let dayStart = now.startOfUTCDay
    return try database.readMapping { db in
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
