import ClawCore

/// Shared `TypingIndicator` doubles for any seam that pulses "typing…" during a long operation.
public struct NoopTyping: TypingIndicator {
  public init() {}

  public func sendTyping(chatId: Int64) async {}
}

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
public actor TypingReleaseGate {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false

  public init() {}

  public func awaitRelease() async {
    if released { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  public func release() {
    guard !released else { return }
    released = true
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
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
