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

/// The ordered routes a turn may use, primary first.
///
/// The type is a list although configuration exposes a single fallback today, so a longer chain is
/// a configuration change rather than a redesign.
public struct ProviderRoster: Sendable {
  private let bindings: [LLMRouteBinding]

  /// - Precondition: `bindings` is non-empty. A roster with no primary is a composition defect, not
  ///   a configuration error, and the factory that builds one fails closed before this point.
  public init(bindings: [LLMRouteBinding]) {
    precondition(bindings.isEmpty == false, "a roster needs at least a primary route")
    self.bindings = bindings
  }

  public var primary: LLMRouteBinding { bindings[0] }
  public var count: Int { bindings.count }
  public var hasFallback: Bool { bindings.count > 1 }

  public func binding(at index: Int) -> LLMRouteBinding { bindings[index] }

  /// The next route to try, or `nil` when the roster is exhausted.
  public func nextIndex(after index: Int) -> Int? {
    let candidate = index + 1
    return candidate < bindings.count ? candidate : nil
  }
}
