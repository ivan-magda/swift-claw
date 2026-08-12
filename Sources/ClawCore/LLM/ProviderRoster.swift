/// One resolved route reduced to exactly what a turn needs to drive it and account for it: the
/// erased provider, the two model identities that split wire traffic from accounting, and the two
/// policies that decide billing and input reservation.
///
/// Credentials are absent by design. The credential source belongs to composition, which owns the
/// shutdown commit; a turn never touches it.
public struct LLMRouteBinding: Sendable {
  public let provider: any LLMProvider
  public let wireModel: String
  public let configuredReference: String
  public let costPolicy: LLMCostPolicy
  public let reservationPolicy: LLMInputReservationPolicy

  public init(
    provider: any LLMProvider,
    wireModel: String,
    configuredReference: String,
    costPolicy: LLMCostPolicy,
    reservationPolicy: LLMInputReservationPolicy
  ) {
    self.provider = provider
    self.wireModel = wireModel
    self.configuredReference = configuredReference
    self.costPolicy = costPolicy
    self.reservationPolicy = reservationPolicy
  }
}

/// Which of the two configured routes a call is on.
public enum RoutePosition: Sendable, Equatable {
  case primary
  case fallback
}

/// The route a call is driving: its position and the binding that serves it.
public struct RouteSelection: Sendable {
  public let position: RoutePosition
  public let binding: LLMRouteBinding

  public init(position: RoutePosition, binding: LLMRouteBinding) {
    self.position = position
    self.binding = binding
  }
}

/// The routes a turn may use: the configured primary plus the optional fallback that takes over.
///
/// This mirrors configuration exactly — one primary, at most one fallback — so there is no index
/// arithmetic and no empty roster to guard against. A third route would be a redesign of this type
/// and of everything that traverses it, not a configuration change.
public struct ProviderRoster: Sendable {
  public let primary: LLMRouteBinding
  public let fallback: LLMRouteBinding?

  public init(primary: LLMRouteBinding, fallback: LLMRouteBinding? = nil) {
    self.primary = primary
    self.fallback = fallback
  }

  public var hasFallback: Bool { fallback != nil }

  /// The route a call starts on: the fallback when the primary is inside a live cooldown window and
  /// a fallback exists, so the call is not spent re-proving a wall it already knows about.
  ///
  /// The window is read by the caller rather than here: the roster is a value the runtime holds
  /// across awaits, while the cooldown is an actor.
  public func startingRoute(primaryIsCooling: Bool) -> RouteSelection {
    guard primaryIsCooling, let fallback else {
      return RouteSelection(position: .primary, binding: primary)
    }
    return RouteSelection(position: .fallback, binding: fallback)
  }

  /// The one failover step a call gets, or `nil` when there is nowhere left to go — no fallback is
  /// configured, or the call is already on it.
  public func failover(from position: RoutePosition) -> RouteSelection? {
    guard position == .primary, let fallback else {
      return nil
    }
    return RouteSelection(position: .fallback, binding: fallback)
  }
}
