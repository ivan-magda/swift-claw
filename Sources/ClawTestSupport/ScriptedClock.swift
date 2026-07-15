import Synchronization

/// A `Clock` whose `sleep` runs a scripted closure with the requested delay — the `Clock`-shaped
/// scripted double for pacing seams. The test decides what a sleep does: return immediately, yield,
/// park on a gate, or throw `CancellationError` to end a service loop.
///
/// Virtual time starts at zero and moves only when a scripted sleep completes, by exactly the delay
/// that was asked for. That is what lets a seam which reads `now` — to hold a deadline, say — be
/// driven to and past that deadline without a test ever waiting for one.
public struct ScriptedClock: Clock {
  public struct Instant: InstantProtocol, Hashable, Sendable {
    public typealias Duration = Swift.Duration

    let offset: Duration

    public func advanced(by duration: Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    public func duration(to other: Instant) -> Duration {
      other.offset - offset
    }

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.offset < rhs.offset
    }
  }

  private let script: @Sendable (Duration) async throws -> Void
  private let elapsed = Elapsed()

  public init(_ script: @escaping @Sendable (Duration) async throws -> Void) {
    self.script = script
  }

  public var now: Instant { Instant(offset: elapsed.value) }
  public var minimumResolution: Duration { .zero }

  /// The script receives the delay the seam asked for, not the absolute deadline, so a scripted
  /// expectation reads the same whether it runs at virtual zero or an hour in.
  ///
  /// Time moves only once the script has returned: a sleep that throws is a sleep that did not
  /// happen, and a deadline already behind us costs nothing rather than winding the clock back.
  public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let delay = now.duration(to: deadline)
    try await script(delay)
    elapsed.advance(by: max(delay, .zero))
  }
}

// MARK: - Virtual Time

private extension ScriptedClock {
  /// Reference-typed so that every copy of a clock value — and `Clock`'s own `sleep(for:)`, which
  /// reads `now` before it sleeps — shares one notion of how far time has moved.
  final class Elapsed: Sendable {
    private let offset = Mutex<Duration>(.zero)

    var value: Duration {
      offset.withLock { current in
        current
      }
    }

    func advance(by delay: Duration) {
      offset.withLock { current in
        current += delay
      }
    }
  }
}
