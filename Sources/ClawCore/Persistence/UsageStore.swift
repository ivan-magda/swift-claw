import Foundation

public enum CostSource: String, Sendable, Equatable {
  case providerReturned = "provider_returned"
  case priceFile = "price_file"
  case heuristic
  /// A subscription route's confirmed zero. It is a distinct source rather than a $0
  /// `providerReturned` so an audit can tell "the plan covered this" from "the provider billed
  /// nothing", and so the never-a-silent-$0 rule is satisfied rather than bypassed.
  case includedPlan = "included_plan"
}

public struct ProviderUsage: Sendable, Equatable {
  /// The provider round-trip this row accounts for. Stored rows are unique on it, which is what
  /// makes a re-attempted commit write nothing instead of double-debiting the day: the second
  /// attempt presents the identity the first one already stored.
  public let providerCallID: ProviderCallID
  /// The owning run, or `nil` for spend issued outside any run (command-scoped LLM calls such as
  /// the /schedule parse). Plain day totals include nil-run rows; the origin-filtered totals
  /// cannot (the JOIN has nothing to match) — correct, since command spend is owner-interactive.
  public let runId: Int64?
  public let sessionId: Int64
  public let model: String
  public let promptTokens: Int
  public let completionTokens: Int
  public let costUSD: Double
  public let costSource: CostSource
  public let isEstimated: Bool
  public let ts: Date
  /// Set only for a learning call, which belongs to no run. It is what carries that spend into the
  /// origin-filtered proactive total: the plain day total sums every row, but the proactive one
  /// resolves an origin through `runs`, and a null `run_id` has nothing there to resolve.
  public let learningScope: LearningUsageScope?

  public init(
    providerCallID: ProviderCallID,
    runId: Int64?,
    sessionId: Int64,
    model: String,
    promptTokens: Int,
    completionTokens: Int,
    costUSD: Double,
    costSource: CostSource,
    isEstimated: Bool,
    ts: Date,
    learningScope: LearningUsageScope? = nil
  ) {
    self.providerCallID = providerCallID
    self.runId = runId
    self.sessionId = sessionId
    self.model = model
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.costUSD = costUSD
    self.costSource = costSource
    self.isEstimated = isEstimated
    self.ts = ts
    self.learningScope = learningScope
  }

  /// Builds the row from its two independent provenances — resolved tokens and resolved cost. This
  /// is the single place the row's `isEstimated` is derived: a row is an estimate iff either input
  /// was guessed.
  public init(
    providerCallID: ProviderCallID,
    runId: Int64?,
    sessionId: Int64,
    model: String,
    usage: ResolvedUsage,
    cost: ResolvedCost,
    ts: Date
  ) {
    self.init(
      providerCallID: providerCallID,
      runId: runId,
      sessionId: sessionId,
      model: model,
      promptTokens: usage.usage.promptTokens,
      completionTokens: usage.usage.completionTokens,
      costUSD: cost.costUSD,
      costSource: cost.source,
      isEstimated: usage.isEstimated || cost.isEstimated,
      ts: ts
    )
  }
}

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
