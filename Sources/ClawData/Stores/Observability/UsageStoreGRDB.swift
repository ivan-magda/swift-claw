import ClawCore
import Foundation
import GRDB

public struct UsageStoreGRDB: UsageStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func recordUsage(_ usage: ProviderUsage) throws(StoreError) {
    _ = try database.writeMapping { db in
      try RunStoreGRDB.insertUsage(db, usage)
    }
  }

  public func todayTokensAndCost(now: Date) throws(StoreError) -> (tokens: Int, costUSD: Double) {
    try database.readMapping { db in
      try Self.dayTotals(db, now: now)
    }
  }

  public func todayTokensAndCost(
    origins: [RunOrigin],
    now: Date
  ) throws(StoreError) -> (tokens: Int, costUSD: Double) {
    try database.readMapping { db in
      try Self.dayTotals(db, origins: origins, now: now)
    }
  }
}

// MARK: - Day Totals

extension UsageStoreGRDB {
  /// The two day totals as in-transaction reads, so a caller that must decide and write in one
  /// commit — the learning authorization is the only one — charges against exactly the arithmetic
  /// the proactive breaker itself uses, rather than a second copy of it that can drift.
  static func dayTotals(_ db: Database, now: Date) throws -> (tokens: Int, costUSD: Double) {
    // GRDB stores Date as a UTC "yyyy-MM-dd HH:mm:ss.SSS" string, so `ts >= ?` is a correct
    // chronological range scan over the calendar-day-UTC window.
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT COALESCE(SUM(prompt_tokens + completion_tokens), 0) AS tokens,
               COALESCE(SUM(cost_usd), 0) AS cost
        FROM provider_usage WHERE ts >= ?
        """,
      arguments: [now.startOfUTCDay]
    )
    guard let row else {
      return (0, 0)
    }
    return (row["tokens"], row["cost"])
  }

  static func dayTotals(
    _ db: Database,
    origins: [RunOrigin],
    now: Date
  ) throws -> (tokens: Int, costUSD: Double) {
    guard origins.isEmpty == false else {
      return (0, 0)
    }
    // databaseQuestionMarks is GRDB's public helper (GRDB/Utils/Utils.swift), not a
    // project symbol — it renders "?,?,?" for the IN clause.
    let placeholders = databaseQuestionMarks(count: origins.count)
    let arguments = StatementArguments(origins.map(\.rawValue)) + [now.startOfUTCDay]
    // A learning call belongs to no run, so the LEFT JOIN leaves it with no origin to match. Its
    // scope columns carry it instead, and only when `.scheduled` is asked for: learning exists
    // only for a scheduled job, so that is the pool its spend charges.
    let learningClause = origins.contains(.scheduled) ? "OR u.learning_job_id IS NOT NULL" : ""
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT COALESCE(SUM(u.prompt_tokens + u.completion_tokens), 0) AS tokens,
               COALESCE(SUM(u.cost_usd), 0) AS cost
        FROM provider_usage u
        LEFT JOIN runs r ON r.id = u.run_id
        WHERE (r.origin IN (\(placeholders)) \(learningClause)) AND u.ts >= ?
        """,
      arguments: arguments
    )
    guard let row else {
      return (0, 0)
    }
    return (row["tokens"], row["cost"])
  }
}

extension UsageStoreGRDB {
  public func latestPromptUsage() throws(StoreError) -> LatestPromptUsage? {
    try database.readMapping { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT prompt_tokens, run_id, is_estimated FROM provider_usage
          ORDER BY id DESC LIMIT 1
          """
      )

      guard let row else {
        return nil
      }

      return LatestPromptUsage(
        promptTokens: row["prompt_tokens"],
        runId: row["run_id"],
        isEstimated: row["is_estimated"]
      )
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
