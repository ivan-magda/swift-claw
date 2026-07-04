import Foundation

/// A gate trip awaiting the owner's ephemeral text approval (§9.2). Carries the canonical URL
/// only; the deterministic prompt text is authored in ClawGateway at the delivery seam (D7).
public struct ExfilApprovalRequest: Sendable, Equatable {
  public let canonicalURL: String

  public init(canonicalURL: String) {
    self.canonicalURL = canonicalURL
  }
}

/// The single-use, one-turn grant a `yes` arms: it authorizes exactly one future fetch of the
/// exact canonical URL if the model re-proposes it (grant semantics, not recorded-args replay).
public struct OneTurnFetchGrant: Sendable, Equatable {
  public let canonicalURL: String

  public init(canonicalURL: String) {
    self.canonicalURL = canonicalURL
  }
}
