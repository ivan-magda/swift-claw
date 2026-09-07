import ClawTestSupport
import Foundation

final class CooperativeCallback: Sendable {
  let entered = AsyncGate()
  let cancelled = AsyncGate()

  func suspend() async throws {
    try await withTaskCancellationHandler {
      entered.open()
      try await Task.sleep(for: .seconds(30))
    } onCancel: {
      cancelled.open()
    }
  }
}

enum CooperativeCallbackBoundary: CaseIterable, Sendable {
  case willLaunch, didLaunch, standardOutput
}
