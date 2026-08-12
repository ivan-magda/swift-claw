/// The cooldown surface a turn depends on, so the runtime is not generic over a clock it never
/// reads itself.
public protocol PrimaryRouteCooldownTracking: Sendable {
  func arm(persistence: RouteFailurePersistence, retryAfterSeconds: Int?) async
  func isCooling() async -> Bool
  func recordSuccess() async -> Bool
  func remainingSeconds() async -> Int?
}

/// The primary route's cooldown window, so an exhausted plan is not probed on every turn.
public actor PrimaryRouteCooldown<ClockType: Clock> where ClockType.Duration == Duration {
  private struct Window {
    var expiresAt: ClockType.Instant
    var armedSeconds: Int
  }

  private let shortSeconds: Int
  private let longSeconds: Int
  private let capSeconds: Int
  private let clock: ClockType
  private var window: Window?

  public init(
    shortSeconds: Int = 60,
    longSeconds: Int,
    capSeconds: Int = 3600,
    clock: ClockType
  ) {
    self.shortSeconds = shortSeconds
    self.longSeconds = longSeconds
    self.capSeconds = capSeconds
    self.clock = clock
  }

  public func arm(persistence: RouteFailurePersistence, retryAfterSeconds: Int?) {
    let tierSeconds = persistence == .long ? longSeconds : shortSeconds
    let base = window.map { min(capSeconds, $0.armedSeconds * 2) } ?? tierSeconds
    let bounded = min(capSeconds, max(base, retryAfterSeconds ?? 0))
    window = Window(
      expiresAt: clock.now.advanced(by: .seconds(bounded)),
      armedSeconds: bounded
    )
  }

  public func isCooling() -> Bool {
    if let window {
      return window.expiresAt > clock.now
    }
    return false
  }

  public func remainingSeconds() -> Int? {
    guard
      let window,
      window.expiresAt > clock.now
    else {
      return nil
    }
    return Int(clock.now.duration(to: window.expiresAt).components.seconds)
  }

  public func recordSuccess() -> Bool {
    if let lapsing = window {
      window = nil
      return lapsing.expiresAt <= clock.now
    }
    return false
  }
}

extension PrimaryRouteCooldown: PrimaryRouteCooldownTracking {}
