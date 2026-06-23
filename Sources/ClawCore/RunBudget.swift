import Foundation

/// The pinned spend bounds for one run and one day. All fields are config-overridable; the
/// hard offline failsafe is `dayTokenCeiling` (D1), derived so the three pricing numbers can
/// never drift out of sync. USD caps are the user-facing limits, enforced when a price is known.
public struct RunBudget: Sendable, Equatable {
  public let maxInputTokens: Int
  public let maxOutputTokens: Int
  public let wallClockDeadlineSeconds: Int
  public let retryBudget: Int
  public let perRunUSD: Double
  public let perDayUSD: Double
  public let referenceUSDPerToken: Double
  public let dayTokenCeilingOverride: Int?

  public init(
    maxInputTokens: Int,
    maxOutputTokens: Int,
    wallClockDeadlineSeconds: Int,
    retryBudget: Int,
    perRunUSD: Double,
    perDayUSD: Double,
    referenceUSDPerToken: Double,
    dayTokenCeilingOverride: Int? = nil
  ) {
    self.maxInputTokens = maxInputTokens
    self.maxOutputTokens = maxOutputTokens
    self.wallClockDeadlineSeconds = wallClockDeadlineSeconds
    self.retryBudget = retryBudget
    self.perRunUSD = perRunUSD
    self.perDayUSD = perDayUSD
    self.referenceUSDPerToken = referenceUSDPerToken
    self.dayTokenCeilingOverride = dayTokenCeilingOverride
  }

  /// Hard offline per-day failsafe. With the defaults this is 666_666 — two orders of magnitude
  /// above one run's bound (`maxInputTokens + maxOutputTokens`), so the two never contradict.
  public var dayTokenCeiling: Int {
    if let dayTokenCeilingOverride {
      return dayTokenCeilingOverride
    }
    return Int((perDayUSD / referenceUSDPerToken).rounded(.down))
  }

  public static let `default` = RunBudget(
    maxInputTokens: 100_000,
    maxOutputTokens: 4_096,
    wallClockDeadlineSeconds: 180,
    retryBudget: 3,
    perRunUSD: 0.50,
    perDayUSD: 10.00,
    referenceUSDPerToken: 0.000_015
  )
}

/// The outcome of an offline budget preflight. `deny` names the tripped cap so the gateway can
/// render a plain-language stop message without knowing the gate's internals.
public enum BudgetDecision: Sendable, Equatable {
  case allow
  case deny(cap: String)
}

/// Offline, pre-call spend gate. Reads today's running totals (derived from `provider_usage`,
/// D4) and this run's estimate, and refuses before any provider call when a cap is met.
public struct BudgetGate: Sendable {
  public let budget: RunBudget

  public init(budget: RunBudget) {
    self.budget = budget
  }

  /// Deny when any spend bound is met. The offline-guaranteed token failsafe (D1) is checked
  /// before the best-effort USD caps, so it still trips when no price is known (`estimatedCostUSD`
  /// defaults to 0).
  public func preflight(
    todayTokens: Int,
    todayUSD: Double,
    estimatedTotalTokens: Int,
    estimatedCostUSD: Double = 0
  ) -> BudgetDecision {
    if todayUSD >= budget.perDayUSD {
      return .deny(cap: "per-day spend")
    }
    if todayTokens + estimatedTotalTokens > budget.dayTokenCeiling {
      return .deny(cap: "per-day token")
    }
    if estimatedCostUSD > budget.perRunUSD {
      return .deny(cap: "per-run spend")
    }
    if todayUSD + estimatedCostUSD > budget.perDayUSD {
      return .deny(cap: "per-day spend")
    }
    return .allow
  }
}
