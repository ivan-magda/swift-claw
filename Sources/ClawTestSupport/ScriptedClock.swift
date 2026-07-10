/// A `Clock` whose `sleep` runs a scripted closure with the requested delay — the `Clock`-shaped
/// scripted double for pacing seams. The test decides what a sleep does: return immediately, yield,
/// park on a gate, or throw `CancellationError` to end a service loop. `now` is frozen at zero;
/// the production seams only ever sleep, they never read the instant.
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

  public init(_ script: @escaping @Sendable (Duration) async throws -> Void) {
    self.script = script
  }

  public var now: Instant { Instant(offset: .zero) }
  public var minimumResolution: Duration { .zero }

  /// With `now` frozen at zero, the deadline offset IS the delay `sleep(for:)` was asked for,
  /// so the script receives exactly what the seam requested.
  public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    try await script(deadline.offset)
  }
}
