import ClawAgent
import ClawCore

/// Shared spelling retained for tests that predate the production no-op collaborator.
package typealias NoopTyping = ClawAgent.NoopTypingIndicator

/// Records every typing pulse so "issued at least once", "never issued", and "issued into the
/// calling topic" are all observable.
public actor RecordingTyping: TypingIndicator {
  public struct Pulse: Sendable, Equatable {
    public let chatId: Int64
    public let messageThreadId: Int64?

    public init(chatId: Int64, messageThreadId: Int64?) {
      self.chatId = chatId
      self.messageThreadId = messageThreadId
    }
  }

  public private(set) var pulses: [Pulse] = []

  public var calls: Int {
    pulses.count
  }

  public init() {}

  public func sendTyping(chatId: Int64, messageThreadId: Int64?) async {
    pulses.append(Pulse(chatId: chatId, messageThreadId: messageThreadId))
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

  public func sendTyping(chatId: Int64, messageThreadId: Int64?) async {
    calls += 1
    await gate.release()
  }
}

/// Records typing pulses and releases `gate` once the requested count has been reached.
public actor CountingReleaseTyping: TypingIndicator {
  public private(set) var pulses: [RecordingTyping.Pulse] = []

  private let releaseAfter: Int
  private let gate: TypingReleaseGate

  public init(releaseAfter: Int, gate: TypingReleaseGate) {
    self.releaseAfter = releaseAfter
    self.gate = gate
  }

  public func sendTyping(chatId: Int64, messageThreadId: Int64?) async {
    pulses.append(RecordingTyping.Pulse(chatId: chatId, messageThreadId: messageThreadId))
    if pulses.count >= releaseAfter {
      await gate.release()
    }
  }
}
