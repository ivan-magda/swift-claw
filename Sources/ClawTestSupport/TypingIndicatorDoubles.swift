import ClawAgent
import ClawCore

/// Shared spelling retained for tests that predate the production no-op collaborator.
package typealias NoopTyping = ClawAgent.NoopTypingIndicator

/// Counts typing pulses so "issued at least once" and "never issued" are both observable.
public actor RecordingTyping: TypingIndicator {
  public private(set) var calls = 0

  public init() {}

  public func sendTyping(chatId: Int64) async {
    calls += 1
  }
}

/// A one-shot release signal: `awaitRelease` suspends until `release` is called once. Pins the
/// producer-after-typing ordering that a raw activity race would leave to scheduler luck.
///
/// A thin latch over the shared `AsyncGate` so the module carries one gate implementation, not two.
/// `awaitRelease` maps to the cancellation-ignoring wait, preserving this gate's original behavior:
/// a waiter parked here stays parked until `release`, so an ordering pin is not undone by a stray
/// cancellation.
public actor TypingReleaseGate {
  private let gate = AsyncGate()

  public init() {}

  public func awaitRelease() async {
    await gate.waitIgnoringCancellation()
  }

  public func release() {
    gate.open()
  }
}

/// Releases `gate` on its first pulse, so a gated producer cannot finish before the owner has
/// seen "typing…" — making "typing was issued" deterministic.
public actor GatingTyping: TypingIndicator {
  public private(set) var calls = 0
  private let gate: TypingReleaseGate

  public init(gate: TypingReleaseGate) {
    self.gate = gate
  }

  public func sendTyping(chatId: Int64) async {
    calls += 1
    await gate.release()
  }
}
