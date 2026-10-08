import ClawCore

/// Aggregate diagnostics never inspect files or expose their contents and date lists.
public enum JournalHealth {
  public static func render(policy: JournalPolicy, status: JournalStatus) -> String {
    """
    Journal: \(policy.enabled ? "enabled" : "disabled")
    Timezone: \(policy.timeZoneID)
    Pending: \(status.pendingCount)
    Last outcome: \(outcomeName(status.lastOutcome))
    Skipped: \(status.skippedCount) · Interrupted: \(status.interruptedCount)
    Last error: \(status.lastRedactedError ?? "none")
    """
  }

  public static func rows(
    policy: JournalPolicy,
    status: HealthValue<JournalStatus>
  ) -> [DoctorReport.Check] {
    [
      DoctorReport.Check(
        key: "journal.enabled",
        value: policy.enabled ? "on" : "off",
        ok: true,
        group: .context
      ),
      .storeRead(status, key: "journal.status", group: .context) { status in
        render(policy: policy, status: status)
      },
    ]
  }
}

// MARK: - Outcome Labels

private extension JournalHealth {
  static func outcomeName(_ outcome: JournalOutcome?) -> String {
    switch outcome {
    case .written:
      "written"
    case .empty:
      "empty"
    case .invalidSummary:
      "invalid summary"
    case .failed:
      "failed"
    case .skipped:
      "skipped"
    case .cancelled:
      "cancelled"
    case .interrupted:
      "interrupted"
    case nil:
      "none"
    }
  }
}
