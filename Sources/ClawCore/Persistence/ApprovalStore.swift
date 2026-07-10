import Foundation

/// The four outcomes of the approve CAS. Only `.approved`/`.stalePolicy` mutate the
/// row (each with its own same-txn audit); `.notPending`/`.expiredRow` leave it untouched for the
/// caller to route (duplicate-tap toast, or the deny path for an aged-out row).
public enum ApprovalApproveOutcome: Sendable, Equatable {
  case approved(Approval)
  case stalePolicy(Approval)
  case notPending
  case expiredRow
}

public protocol ApprovalStore: Sendable {
  /// Lookup by nonce ONLY (the callback's single-use credential), never by id.
  func approval(nonce: String) throws -> Approval?
  func approval(id: Int64) throws -> Approval?
  /// One transaction: still PENDING, unexpired, stored argsHash ==
  /// `ApprovalArgsHash.sha256Hex(canonicalArgsJSON)`, and storedPolicyVersion ==
  /// `currentPolicyVersion`. All satisfied → APPROVED + `approvalGranted`. Hash/version mismatch
  /// → REJECTED + decision `stale_policy` + `approvalDenied`, returns `.stalePolicy`.
  func approve(id: Int64, currentPolicyVersion: String, now: Date) throws
    -> ApprovalApproveOutcome
  /// CAS PENDING→(EXPIRED when decision is `.expired`, else REJECTED) + `approvalDenied` audit in
  /// the same txn. false when the row is no longer PENDING (a racing resolver won).
  func deny(id: Int64, decision: ApprovalDecision, now: Date) throws -> Bool
  /// Ticker/boot sweep: CAS every PENDING row with `expires_ts <= now` → EXPIRED (+ `approvalDenied`
  /// audit, decision `expired`) and return the swept rows for the waiter signals.
  func sweepExpired(now: Date) throws -> [Approval]
  /// Boot: PENDING rows (any expiry), plus resolved rows whose run is still AWAITING_APPROVAL —
  /// APPROVED (the grant crash window) and REJECTED/EXPIRED (the deny-side twin: the deny CAS +
  /// audit committed but the waiter's run-fail commit did not). Terminal-run rows never return.
  func unresolvedAtBoot() throws -> [Approval]
  /// Boot hygiene: a terminal run holding a PENDING approval → REJECTED + `approvalDenied`
  /// (decision `cancelled`). Returns the count cleaned.
  func resolveOrphans(now: Date) throws -> Int
  /// Doctor: outstanding PENDING count + the oldest pending row's age.
  func approvalsHealth(now: Date) throws -> ApprovalsHealth
}
