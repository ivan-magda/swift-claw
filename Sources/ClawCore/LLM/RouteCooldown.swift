/// The cooldown surface a turn depends on, so the runtime is not generic over a clock it never
/// reads itself.
public protocol RouteCooldownTracking: Sendable {
  func arm(routeIndex: Int, persistence: RouteFailurePersistence, retryAfterSeconds: Int?) async
  func isCooling(routeIndex: Int) async -> Bool
  func consumeExpired(routeIndex: Int) async -> Bool
  func clear(routeIndex: Int) async
}

/// Per-route cooldown windows, so an exhausted plan is not probed on every turn.
///
/// State is in memory on purpose. The daemon is long-running, and a restart costs exactly one
/// probe against a route that may already have recovered.
public actor RouteCooldown<ClockType: Clock> where ClockType.Duration == Duration {
  private struct Window {
    var expiresAt: ClockType.Instant
    var armedSeconds: Int
    /// Set when the window lapses without the route being cleared, so the first turn that probes
    /// the route again can tell the owner it is answering.
    var expiryReported: Bool
  }

  private let shortSeconds: Int
  private let longSeconds: Int
  private let capSeconds: Int
  private let clock: ClockType
  private var windows: [Int: Window] = [:]

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

  /// Arms or re-arms the window for a route. Any re-arm while a window entry still exists —
  /// whether that window is live or already lapsed — doubles the previous armed duration, up to
  /// the cap; a route with no prior entry starts at the tier default. Callers only re-arm a route
  /// that has just failed, so an existing entry always means a prior failure, and doubling it is
  /// the backoff. A hint larger than the tier default wins; a smaller one is ignored, because the
  /// parsed provider hint is clamped for retry pacing and says nothing about when a plan resets.
  public func arm(
    routeIndex: Int,
    persistence: RouteFailurePersistence,
    retryAfterSeconds: Int?
  ) {
    let tierSeconds = persistence == .long ? longSeconds : shortSeconds
    let base = windows[routeIndex].map { min(capSeconds, $0.armedSeconds * 2) } ?? tierSeconds
    let bounded = min(capSeconds, max(base, retryAfterSeconds ?? 0))
    windows[routeIndex] = Window(
      expiresAt: clock.now.advanced(by: .seconds(bounded)),
      armedSeconds: bounded,
      expiryReported: false
    )
  }

  /// Whether the route is inside a live window.
  public func isCooling(routeIndex: Int) -> Bool {
    guard let window = windows[routeIndex] else { return false }
    return window.expiresAt > clock.now
  }

  public func remainingSeconds(routeIndex: Int) -> Int? {
    guard let window = windows[routeIndex], window.expiresAt > clock.now else { return nil }
    return Int(clock.now.duration(to: window.expiresAt).components.seconds)
  }

  /// Reports once that a route's window lapsed, so exactly one turn tells the owner the route is
  /// answering again. The doubling history survives, because a lapsed window that has not yet
  /// proven the route healthy must still double if the probe fails.
  public func consumeExpired(routeIndex: Int) -> Bool {
    guard var window = windows[routeIndex] else { return false }
    guard window.expiresAt <= clock.now, window.expiryReported == false else { return false }
    window.expiryReported = true
    windows[routeIndex] = window
    return true
  }

  /// Drops the window and the doubling history after the route answers successfully.
  public func clear(routeIndex: Int) {
    windows[routeIndex] = nil
  }
}

extension RouteCooldown: RouteCooldownTracking {}
