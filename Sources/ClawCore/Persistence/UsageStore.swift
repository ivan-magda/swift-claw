import Foundation

public protocol UsageStore: Sendable {
  func recordUsage(_ usage: ProviderUsage) throws(StoreError)
  /// Running totals over `provider_usage` for the calendar-day-UTC window containing `now`.
  func todayTokensAndCost(now: Date) throws(StoreError) -> (tokens: Int, costUSD: Double)
  /// The same UTC-day window as `todayTokensAndCost(now:)`, restricted to usage whose run's
  /// origin is IN `origins` (JOIN provider_usage.run_id → runs.id — no denormalized origin
  /// on usage rows). One query, one day-boundary evaluation.
  func todayTokensAndCost(origins: [RunOrigin], now: Date) throws(StoreError) -> (
    tokens: Int, costUSD: Double
  )
  /// Count of `provider_usage` rows per `CostSource` in the calendar-day-UTC window (for doctor).
  func costSourceMix(now: Date) throws(StoreError) -> [CostSource: Int]
}
