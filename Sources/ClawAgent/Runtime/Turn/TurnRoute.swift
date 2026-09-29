import ClawCore

/// The route a turn is driving and the one route notice it owes the owner. A turn switches at most
/// once, primary to fallback, and only the primary carries a cooldown window.
struct TurnRoute {
  /// A switch the turn just made: the route it left, the route it moved to, and the cooldown it
  /// armed on the one it left.
  struct Transition {
    let previous: String
    let successor: String
    let persistence: RouteFailurePersistence
  }

  private(set) var active: ActiveRoute
  /// The one route transition this turn owes the owner.
  private(set) var notice: RouteNotice?

  private let roster: ProviderRoster
  private let cooldown: (any PrimaryRouteCooldownTracking)?
  private let budget: RunBudget
  private let costResolver: CostResolver
  private let usageResolver: UsageResolver

  /// Starts on the fallback while the primary is cooling, so the round-trip is spent on a route
  /// that can answer instead of re-proving the wall.
  init(
    roster: ProviderRoster,
    cooldown: (any PrimaryRouteCooldownTracking)?,
    budget: RunBudget,
    costResolver: CostResolver,
    usageResolver: UsageResolver
  ) async {
    let primaryIsCooling = await cooldown?.isCooling() == true
    active = ActiveRoute(
      selection: roster.startingRoute(primaryIsCooling: primaryIsCooling),
      budget: budget,
      costResolver: costResolver,
      usageResolver: usageResolver
    )

    self.roster = roster
    self.cooldown = cooldown
    self.budget = budget
    self.costResolver = costResolver
    self.usageResolver = usageResolver
  }

  /// Moves to the fallback when `error` permits a switch and one is configured, arming the
  /// primary's cooldown first. Returns nil, changing nothing, when the turn must degrade instead.
  mutating func switchRoute(after error: any Error) async -> Transition? {
    guard let persistence = RouteSwitch.permits(error),
          let next = roster.failover(from: active.position)
    else {
      return nil
    }

    let previous = active.binding.configuredReference
    await cooldown?.arm(
      persistence: persistence,
      retryAfterSeconds: RouteSwitch.retryAfterSeconds(of: error)
    )

    active = ActiveRoute(
      selection: next,
      budget: budget,
      costResolver: costResolver,
      usageResolver: usageResolver
    )
    let successor = active.binding.configuredReference
    notice = .switched(from: previous, to: successor)

    return Transition(previous: previous, successor: successor, persistence: persistence)
  }

  /// Records that the active route answered. A primary answer drops its cooldown window and owes
  /// the restored notice when that window had lapsed rather than been cleared; only the first
  /// answer can owe it, because a later one finds the window already cleared.
  mutating func recordAnswer() async {
    guard active.position == .primary, notice == nil, let cooldown else {
      return
    }

    if await cooldown.recordSuccess() {
      notice = .restored(route: active.binding.configuredReference)
    }
  }
}
