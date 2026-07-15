import ClawCore
import Foundation

/// One `ProviderUsage` spend row with every field defaulted to the plain heuristic case the Run
/// store suites reuse; each test overrides only the field it exercises (token counts, `isEstimated`,
/// `model`, `costSource`, `ts`). Kept in `ClawDataTests` — no other target seeds usage rows.
///
/// `callID` defaults to a fixed identity rather than a fresh one: rows are unique on it, so a suite
/// that seeds two rows without naming their calls is asserting on a duplicate and should say so.
func makeProviderUsage(
  runId: Int64?,
  sessionId: Int64,
  callID: String = "call-1",
  model: String = "m",
  promptTokens: Int = 10,
  completionTokens: Int = 5,
  costUSD: Double = 0.001,
  costSource: CostSource = .heuristic,
  isEstimated: Bool = false,
  ts: Date = Date()
) -> ProviderUsage {
  ProviderUsage(
    providerCallID: ProviderCallID(rawValue: callID),
    runId: runId,
    sessionId: sessionId,
    model: model,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    costUSD: costUSD,
    costSource: costSource,
    isEstimated: isEstimated,
    ts: ts
  )
}
