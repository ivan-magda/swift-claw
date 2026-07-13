import ClawCore

/// Seeds the configured owner IDs into the allowlist at daemon start and classifies a seed failure
/// by whether it strands the owner boundary.
///
/// `AccessControl` default-denies against the allowlist table, so a seed that fails while owners are
/// configured boots the daemon locked out of its own owners even though the config is valid, while
/// every other health signal still looks fine. That state must abort boot rather than run silently
/// locked out. With no owners configured there is nothing to strand, so an onboarding boot may
/// proceed on the empty allowlist.
public enum AllowlistSeeding {
  public enum Outcome: Sendable, Equatable {
    /// The configured owners are in the table (or none were configured and the write succeeded).
    case seeded
    /// The seed failed with no owners configured; an onboarding boot may proceed.
    case toleratedFailure(StoreError)
    /// The seed failed with owners configured; the daemon would boot locked out and must abort.
    case strandedOwners(StoreError)
  }

  /// Additive seed — an ID dropped from config is not revoked here; revocation is deferred to
  /// pairing, which needs an audited remove path rather than a config-mirroring reconcile.
  public static func seed(into allowlist: any AllowlistStore, owners: Set<Int64>) -> Outcome {
    do {
      try allowlist.seedAllowlist(userIds: Array(owners))
      return .seeded
    } catch {
      return owners.isEmpty ? .toleratedFailure(error) : .strandedOwners(error)
    }
  }
}
