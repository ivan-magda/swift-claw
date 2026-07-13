import ClawCore
import Foundation

/// One `ProviderUsage` spend row with every field defaulted to the plain heuristic case the Run
/// store suites reuse; each test overrides only the field it exercises (token counts, `isEstimated`,
/// `model`, `costSource`, `ts`). Kept in `ClawDataTests` — no other target seeds usage rows.
func makeProviderUsage(
  runId: Int64?,
  sessionId: Int64,
  model: String = "m",
  promptTokens: Int = 10,
  completionTokens: Int = 5,
  costUSD: Double = 0.001,
  costSource: CostSource = .heuristic,
  isEstimated: Bool = false,
  ts: Date = Date()
) -> ProviderUsage {
  ProviderUsage(
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
