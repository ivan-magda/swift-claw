/// The four durable approval states — never a fifth: a `/stop`//`new`
/// resolution lands in REJECTED and the audit `decision` records why.
public enum ApprovalState: String, Sendable, Equatable {
  case pending = "PENDING"
  case approved = "APPROVED"
  case rejected = "REJECTED"
  case expired = "EXPIRED"
}

public enum ApprovalEvent: Sendable, Equatable {
  /// A valid callback: auth + nonce + args-hash + policy_version all OK (the approve guard).
  case approve
  /// Owner deny, stale-policy deny, or run cancel/supersede — the audit decision says why.
  case reject
  /// The expiry ticker or boot sweep aged the row out.
  case expire
}

/// The ApprovalState table from ARCHITECTURE.md §19.1. Exhaustive switch, no default arm; nil =
/// illegal (a resolved row never moves again — that is the single-use guarantee's substrate).
public enum ApprovalFSM {
  public static func reduce(state: ApprovalState, on event: ApprovalEvent) -> ApprovalState? {
    switch (state, event) {
    case (.pending, .approve): .approved
    case (.pending, .reject): .rejected
    case (.pending, .expire): .expired
    case (.approved, _), (.rejected, _), (.expired, _): nil
    }
  }
}
