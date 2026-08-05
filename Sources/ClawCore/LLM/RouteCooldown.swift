/// The cooldown surface a turn depends on, so the runtime is not generic over a clock it never
/// reads itself.
public protocol RouteCooldownTracking: Sendable {
  func arm(routeIndex: Int, persistence: RouteFailurePersistence, retryAfterSeconds: Int?) async
  func isCooling(routeIndex: Int) async -> Bool
  func recordSuccess(routeIndex: Int) async -> Bool
  func remainingSeconds(routeIndex: Int) async -> Int?
}

/// Per-route cooldown windows, so an exhausted plan is not probed on every turn.
///
/// State is in memory on purpose. The daemon is long-running, and a restart costs exactly one
/// probe against a route that may already have recovered.
public actor RouteCooldown<ClockType: Clock> where ClockType.Duration == Duration {
  private struct Window {
    var expiresAt: ClockType.Instant
    var armedSeconds: Int
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
      armedSeconds: bounded
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

  /// Records that the route answered: drops its window and the doubling history, and reports
  /// whether the window it dropped had already lapsed — the one turn that owes the owner a "this
  /// route is carrying traffic again" notice.
  ///
  /// Reading and dropping in ONE actor hop is the point. A separate read-then-clear pair leaves a
  /// gap another turn can arm a fresh window inside, and the clear would then erase both that
  /// window and its doubling history — sending the next turn back at a route known to be walled
  /// off, with the backoff restarted at the tier default.
  public func recordSuccess(routeIndex: Int) -> Bool {
    guard let window = windows.removeValue(forKey: routeIndex) else { return false }
    return window.expiresAt <= clock.now
  }
}

extension RouteCooldown: RouteCooldownTracking {}
