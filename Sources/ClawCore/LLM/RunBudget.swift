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
  /// The nested proactive (scheduled + heartbeat) daily pool (S3). Always intended < perDayUSD —
  /// the global cap stays the household kill-switch; this bounds unattended spend alone.
  public let proactivePerDayUSD: Double
  public let referenceUSDPerToken: Double
  public let maxTurns: Int
  public let maxToolCalls: Int
  public let dayTokenCeilingOverride: Int?

  public init(
    maxInputTokens: Int,
    maxOutputTokens: Int,
    wallClockDeadlineSeconds: Int,
    retryBudget: Int,
    perRunUSD: Double,
    perDayUSD: Double,
    proactivePerDayUSD: Double,
    referenceUSDPerToken: Double,
    maxTurns: Int = 12,
    maxToolCalls: Int = 20,
    dayTokenCeilingOverride: Int? = nil
  ) {
    self.maxInputTokens = maxInputTokens
    self.maxOutputTokens = maxOutputTokens
    self.wallClockDeadlineSeconds = wallClockDeadlineSeconds
    self.retryBudget = retryBudget
    self.perRunUSD = perRunUSD
    self.perDayUSD = perDayUSD
    self.proactivePerDayUSD = proactivePerDayUSD
    self.referenceUSDPerToken = referenceUSDPerToken
    self.maxTurns = maxTurns
    self.maxToolCalls = maxToolCalls
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
    proactivePerDayUSD: 2.00,
    referenceUSDPerToken: 0.000_015,
    maxTurns: 12,
    maxToolCalls: 20
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
  /// The cap name a proactive trip emits. TurnRunner keys the once-per-UTC-day owner DM on it,
  /// so it is a single named definition, not a call-site string.
  public static let proactivePerDayCap = "proactive per-day spend"
  /// The remaining cap names, likewise defined once so callers and tests share one source of truth.
  public static let perDaySpendCap = "per-day spend"
  public static let perDayTokenCap = "per-day token"
  public static let perRunSpendCap = "per-run spend"

  public let budget: RunBudget

  public init(budget: RunBudget) {
    self.budget = budget
  }

  /// Deny when any spend bound is met. The offline-guaranteed token failsafe (D1) is checked
  /// before the best-effort USD caps, so it still trips when no price is known (`estimatedCostUSD`
  /// defaults to 0). Global checks run first, unchanged order — then, iff the run is proactive
  /// (`origin != .interactive`), the nested proactive pool is consulted (spec §11).
  public func preflight(
    todayTokens: Int,
    todayUSD: Double,
    estimatedTotalTokens: Int,
    estimatedCostUSD: Double = 0,
    origin: RunOrigin = .interactive,
    proactiveTodayUSD: Double = 0
  ) -> BudgetDecision {
    if todayUSD >= budget.perDayUSD {
      return .deny(cap: Self.perDaySpendCap)
    }
    if todayTokens + estimatedTotalTokens > budget.dayTokenCeiling {
      return .deny(cap: Self.perDayTokenCap)
    }
    if estimatedCostUSD > budget.perRunUSD {
      return .deny(cap: Self.perRunSpendCap)
    }
    if todayUSD + estimatedCostUSD > budget.perDayUSD {
      return .deny(cap: Self.perDaySpendCap)
    }
    if origin != .interactive {
      if proactiveTodayUSD >= budget.proactivePerDayUSD {
        return .deny(cap: Self.proactivePerDayCap)
      }
      if proactiveTodayUSD + estimatedCostUSD > budget.proactivePerDayUSD {
        return .deny(cap: Self.proactivePerDayCap)
      }
    }
    return .allow
  }
}
