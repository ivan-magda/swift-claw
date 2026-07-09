import ClawAgent
import ClawCore
import Foundation
import Logging

// `ApprovalParking` is already declared in `ApprovalCoordinator.swift` (Task 14) and `ApprovalWaiter`
// already conforms to it (Task 16, Step 20) — both in this same `ClawGateway` module. Do NOT
// redeclare the protocol or re-add the conformance here: a second `public protocol ApprovalParking`
// is an "invalid redeclaration" build error, and a second `extension ApprovalWaiter: ApprovalParking`
// is a redundant conformance. The reconciler just USES the existing protocol as its `waiter`
// dependency type — it is already the single `park` method the boot path needs, so no narrowing is
// required. In tests the boot spy conforms to that same existing protocol.

/// §7 boot reconciliation for the approval fabric — the restart entry point of the §5.5 single
/// execution locus. It never transitions a run row directly: it cleans terminal-run orphans, then
/// per unresolved approval either re-parks a waiter on the session lane (unexpired PENDING),
/// CAS-expires + signals a denial for the parked waiter to consume (expired PENDING), re-parks
/// under the §6.5 crash-window belt (APPROVED row on an AWAITING_APPROVAL run), or re-buffers the
/// already-committed denial (REJECTED/EXPIRED row on an AWAITING_APPROVAL run — the deny-side
/// crash window). The parked waiter performs every run transition, owner notice, and button
/// disarm; the reconciler only orchestrates.
public struct ApprovalBootReconciler: Sendable {
  private let approvals: any ApprovalStore
  private let lanes: SessionLaneRegistry
  private let coordinator: ApprovalCoordinator
  private let waiter: any ApprovalParking
  private let now: @Sendable () -> Date
  private let logger: Logger

  public init(
    approvals: any ApprovalStore,
    lanes: SessionLaneRegistry,
    coordinator: ApprovalCoordinator,
    waiter: any ApprovalParking,
    now: @escaping @Sendable () -> Date,
    logger: Logger
  ) {
    self.approvals = approvals
    self.lanes = lanes
    self.coordinator = coordinator
    self.waiter = waiter
    self.now = now
    self.logger = logger
  }

  /// Best-effort and ordered: orphan cleanup runs first so `unresolvedAtBoot`'s PENDING rows all
  /// belong to still-parked (AWAITING_APPROVAL) runs (a suspend commit flips the run and inserts the
  /// row in one txn, so a PENDING approval's run is only ever AWAITING_APPROVAL or terminal). A
  /// failure on one row is logged and never strands the others.
  public func reconcile() async {
    let instant = now()

    do {
      let cleaned = try approvals.resolveOrphans(now: instant)
      if cleaned > 0 {
        logger.warning("boot approvals: resolved \(cleaned) orphaned pending approval(s)")
      }
    } catch {
      logger.error("boot approvals: resolveOrphans failed: \(error)")
    }

    let unresolved: [Approval]
    do {
      unresolved = try approvals.unresolvedAtBoot()
    } catch {
      logger.error("boot approvals: unresolvedAtBoot failed: \(error)")
      return
    }

    for approval in unresolved {
      await reparkOne(approval, now: instant)
    }
  }
}

// MARK: - Per-Row Re-Park

private extension ApprovalBootReconciler {
  func reparkOne(_ approval: Approval, now instant: Date) async {
    let revalidate: Bool

    switch approval.state {
    case .approved:
      // §6.5 crash window: granted before the crash. Buffer the approval signal and re-park under
      // re-validation so the waiter rechecks policy_version before executing the recorded action.
      await coordinator.signal(approvalId: approval.id, .approved)
      revalidate = true
    case .pending where approval.expiresTs <= instant:
      // §6.4 expiry: CAS PENDING→EXPIRED (+ approvalDenied/expired audit) here, then let the parked
      // waiter consume the buffered denial and drive the run AWAITING_APPROVAL→FAILED.
      do {
        // Nothing races the boot sweep, so a lost CAS should be impossible; still signal so the
        // parked waiter frees the lane, but leave a trace instead of silently dropping the miss.
        if try approvals.deny(id: approval.id, decision: .expired, now: instant) == false {
          logger.warning("boot approvals: expiry CAS found approval \(approval.id) not PENDING")
        }
      } catch {
        logger.error("boot approvals: expiry deny failed for approval \(approval.id): \(error)")
        return
      }
      await coordinator.signal(approvalId: approval.id, .denied(.expired))
      revalidate = false
    case .pending:
      // Unexpired: re-park so buttons and the FIFO queue-behind contract survive restart (§5.5).
      revalidate = false
    case .rejected:
      // Deny-side twin of the §6.5 crash window: the deny CAS (+ its audit) committed but the
      // process died before the waiter's observation-fill/run-fail commit. Never re-CAS or
      // re-audit — just re-buffer the denial so the re-parked waiter finalizes the run
      // AWAITING_APPROVAL→FAILED. The original decision (owner reject vs stale policy) is not
      // recoverable from the row; both map to run→FAILED with no cancel, so the generic
      // `.rejected` differs only in owner-notice copy. (Cancel/supersede denials can never land
      // here — the command txn moves the run off AWAITING_APPROVAL atomically with the CAS.)
      await coordinator.signal(approvalId: approval.id, .denied(.rejected))
      revalidate = false
    case .expired:
      // The same deny-side belt for a row the expiry CAS resolved before the crash.
      await coordinator.signal(approvalId: approval.id, .denied(.expired))
      revalidate = false
    }

    let park = waiter
    let approvalId = approval.id
    let runId = approval.runId
    let sessionId = approval.sessionId
    let chatId = approval.ownerUserId
    let lane = await lanes.actor(for: sessionId)

    await lane.enqueue(runId: runId) {
      await park.park(
        approvalId: approvalId,
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        revalidatePolicyOnApprove: revalidate
      )
    }
  }
}
