import Foundation

/// Canonical formatting for USD amounts. Keeps the `%.Nf` precision in one place instead of as a
/// magic format string scattered across turn-cost logs, the doctor report, and scheduler health.
public enum USD {
  /// Sub-cent precision (4 dp) — spend detail: per-turn cost logs and the doctor `spend.today_usd`.
  public static func precise(_ amount: Double) -> String {
    String(format: "%.4f", amount)
  }

  /// Cent precision (2 dp) — owner-facing caps, remaining budget, and proactive-spend display.
  public static func display(_ amount: Double) -> String {
    String(format: "%.2f", amount)
  }
}
