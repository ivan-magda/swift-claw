import ClawCore

/// Renders doctor's approvals health rows from the persisted `approvals` table. Pure
/// so the rendering is unit-testable; doctor is a separate process, so only persisted state is
/// visible to it — the count/age arrive from `ApprovalStore.approvalsHealth` at call time.
///
/// Named `ApprovalsHealthRows` (not `ApprovalsHealth`) so it never collides with the ClawCore
/// `ApprovalsHealth` data struct it renders — ClawGateway imports both.
public enum ApprovalsHealthRows {
  public struct Row: Sendable, Equatable {
    public let key: String
    public let value: String
    public let headline: Bool

    public init(key: String, value: String, headline: Bool = false) {
      self.key = key
      self.value = value
      self.headline = headline
    }
  }

  public static func rows(health: ApprovalsHealth, approvalExpirySeconds: Int) -> [Row] {
    // Oldest pending age shown against the expiry window (age/expiry), mirroring the
    // heartbeat.today "count/cap" idiom — a row nearing the cap flags a stuck approval before the
    // ticker sweeps it.
    let oldestAge =
      health.oldestPendingAgeSeconds.map { age in "\(age)/\(approvalExpirySeconds)" } ?? "none"

    return [
      Row(key: "approvals.pending", value: "\(health.pendingCount)", headline: true),
      Row(key: "approvals.oldest_age_s", value: oldestAge),
    ]
  }
}
