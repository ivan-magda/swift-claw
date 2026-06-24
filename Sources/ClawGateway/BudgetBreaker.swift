import ClawCore
import Foundation

/// Post-commit daily kill-switch. The *refusal* lives in `provider_usage` (durable across restart,
/// enforced by the pre-call `BudgetGate`); this actor only owns the once-per-UTC-day owner DM, which
/// is in-memory by design (D4) — a missed DM after a crash is acceptable, a missed refusal is not.
public actor BudgetBreaker {
  private let budget: RunBudget
  /// The UTC day whose trip has already been DMed; resets implicitly when `now` rolls to a new day.
  private var notifiedDay: Date?

  public init(budget: RunBudget) {
    self.budget = budget
  }

  /// The caller's once-per-day signal to DM the owner: `true` only when today's actuals meet either
  /// cap, and only the first such call per UTC day — the `now.startOfUTCDay` latch collapses repeated
  /// trips within a day to a single DM, even when both `TurnRunner` branches call it.
  public func shouldNotifyTrip(todayTokens: Int, todayUSD: Double, now: Date) -> Bool {
    let capIsMet = todayUSD >= budget.perDayUSD || todayTokens >= budget.dayTokenCeiling
    guard capIsMet else {
      return false
    }

    let utcDayStart = now.startOfUTCDay
    guard notifiedDay != utcDayStart else {
      return false
    }
    notifiedDay = utcDayStart

    return true
  }
}
