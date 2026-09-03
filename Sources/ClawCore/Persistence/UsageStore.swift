import Foundation

/// The most recently recorded call's prompt size — the context the provider last billed for.
/// `runId` is nil for runless spend (e.g. schedule parses). `isEstimated` mirrors the row's fused
/// provenance flag: true when tokens or cost were guessed (usage-omitting response, deadline,
/// ambiguous failure), so callers never present a guess as a provider-confirmed count.
public struct LatestPromptUsage: Sendable, Equatable {
  public let promptTokens: Int
  public let runId: Int64?
  public let isEstimated: Bool

  public init(promptTokens: Int, runId: Int64?, isEstimated: Bool) {
    self.promptTokens = promptTokens
    self.runId = runId
    self.isEstimated = isEstimated
  }
}

public protocol UsageStore: Sendable {
  func recordUsage(_ usage: ProviderUsage) throws(StoreError)
  /// Running totals over `provider_usage` for the calendar-day-UTC window containing `now`.
  func todayTokensAndCost(
    now: Date
  ) throws(StoreError) -> (tokens: Int, costUSD: Double)
  /// The same UTC-day window as `todayTokensAndCost(now:)`, restricted to usage whose run's
  /// origin is IN `origins` (JOIN provider_usage.run_id → runs.id — no denormalized origin
  /// on usage rows). One query, one day-boundary evaluation.
  ///
  /// A learning call has no run to join, so it is counted through its own scope columns instead,
  /// and only when `origins` contains `.scheduled`: learning exists only for a scheduled job, so
  /// that is the pool its spend charges.
  func todayTokensAndCost(
    origins: [RunOrigin],
    now: Date
  ) throws(StoreError) -> (tokens: Int, costUSD: Double)
  /// Count of `provider_usage` rows per `CostSource` in the calendar-day-UTC window (for doctor).
  func costSourceMix(now: Date) throws(StoreError) -> [CostSource: Int]
  /// nil before any call was recorded.
  func latestPromptUsage() throws(StoreError) -> LatestPromptUsage?
}
