import ClawCore

/// Renders doctor's approvals health rows from the persisted `approvals` table. Pure
/// so the rendering is unit-testable; doctor is a separate process, so only persisted state is
/// visible to it — the count/age arrive from `ApprovalStore.approvalsHealth` at call time.
///
/// Named `ApprovalsHealthRows` (not `ApprovalsHealth`) so it never collides with the ClawCore
/// `ApprovalsHealth` data struct it renders — ClawGateway imports both.
public enum ApprovalsHealthRows {
  public static func rows(
    health: HealthValue<ApprovalsHealth>,
    approvalExpirySeconds: Int
  ) -> [DoctorReport.Check] {
    // Oldest pending age shown against the expiry window (age/expiry), mirroring the
    // heartbeat.today "count/cap" idiom — a row nearing the cap flags a stuck approval before the
    // ticker sweeps it.
    return [
      .storeRead(
        health,
        key: "approvals.pending",
        group: .approvals,
        isHeadline: true
      ) { health in
        "\(health.pendingCount)"
      },
      .storeRead(
        health,
        key: "approvals.oldest_age_s",
        group: .approvals
      ) { health in
        health.oldestPendingAgeSeconds.map { age in
          "\(age)/\(approvalExpirySeconds)"
        } ?? "none"
      },
    ]
  }
}
