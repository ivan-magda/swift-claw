import ClawTestSupport
import Foundation
import Testing

final class CooperativeCallback: Sendable {
  let entered = AsyncGate()
  let cancelled = AsyncGate()

  func suspend() async throws {
    try await withTaskCancellationHandler {
      entered.open()
      _ = await AsyncGate().waitUntilOpen()
      try Task.checkCancellation()
      Issue.record("Coder callback did not receive cancellation before its watchdog.")
    } onCancel: {
      cancelled.open()
    }
  }
}

enum CooperativeCallbackBoundary: CaseIterable, Sendable {
  case willLaunch, didLaunch, standardOutput
}
