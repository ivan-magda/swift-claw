import ClawCore

/// Renders doctor's approvals health rows from the persisted `approvals` table. Pure
/// so the rendering is unit-testable; doctor is a separate process, so only persisted state is
/// visible to it — the count/age arrive from `ApprovalStore.approvalsHealth` at call time.
///
/// Named `ApprovalsHealthRows` (not `ApprovalsHealth`) so it never collides with the ClawCore
/// `ApprovalsHealth` data struct it renders — ClawGateway imports both.
public enum ApprovalsHealthRows {
  public static func rows(
    health: ApprovalsHealth,
    approvalExpirySeconds: Int
  ) -> [DoctorReport.Check] {
    // Oldest pending age shown against the expiry window (age/expiry), mirroring the
    // heartbeat.today "count/cap" idiom — a row nearing the cap flags a stuck approval before the
    // ticker sweeps it.
    let oldestAge =
      health.oldestPendingAgeSeconds.map { age in "\(age)/\(approvalExpirySeconds)" } ?? "none"

    return [
      DoctorReport.Check(
        key: "approvals.pending",
        value: "\(health.pendingCount)",
        ok: true,
        group: .approvals,
        isHeadline: true
      ),
      DoctorReport.Check(
        key: "approvals.oldest_age_s",
        value: oldestAge,
        ok: true,
        group: .approvals
      ),
    ]
  }
}
