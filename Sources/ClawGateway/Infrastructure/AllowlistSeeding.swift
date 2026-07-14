import ClawCore

/// Seeds the configured owner IDs into the allowlist at daemon start and classifies a seed failure
/// by whether it strands the owner boundary.
public enum AllowlistSeeding {
  public enum Outcome: Sendable, Equatable {
    /// The configured owners are in the table.
    case seeded
    /// The seed failed with no owners configured; an onboarding boot may proceed.
    case toleratedFailure(StoreError)
    /// The seed failed with owners configured; the daemon would boot locked out and must abort.
    case strandedOwners(StoreError)
  }

  public static func seed(into allowlist: any AllowlistStore, owners: Set<Int64>) -> Outcome {
    do {
      try allowlist.seedAllowlist(userIds: Array(owners))
      return .seeded
    } catch {
      return owners.isEmpty ? .toleratedFailure(error) : .strandedOwners(error)
    }
  }
}
