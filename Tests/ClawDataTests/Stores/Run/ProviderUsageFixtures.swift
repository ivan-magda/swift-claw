import ClawCore
import Foundation

/// One `ProviderUsage` spend row with every field defaulted to the plain heuristic case the Run
/// store suites reuse; each test overrides only the field it exercises (token counts, `isEstimated`,
/// `model`, `costSource`, `ts`). Kept in `ClawDataTests` — no other target seeds usage rows.
///
/// `callID` defaults to a fresh identity because rows are unique on it and the store's insert
/// resolves a conflict by doing nothing: a shared default would let a suite seed two rows, store
/// one, and still pass. Tests that assert on the identity itself pass an explicit `callID`.
func makeProviderUsage(
  runId: Int64?,
  sessionId: Int64,
  callID: String = UUIDProviderCallIDGenerator().next().rawValue,
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
