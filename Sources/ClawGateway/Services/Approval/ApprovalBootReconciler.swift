import ClawAgent
import ClawCore
import Foundation
import Logging

// `ApprovalParking` is already declared in `ApprovalCoordinator.swift` and `ApprovalWaiter`
// already conforms to it — both in this same `ClawGateway` module. Do NOT
// redeclare the protocol or re-add the conformance here: a second `public protocol ApprovalParking`
// is an "invalid redeclaration" build error, and a second `extension ApprovalWaiter: ApprovalParking`
// is a redundant conformance. The reconciler just USES the existing protocol as its `waiter`
// dependency type — it is already the single `park` method the boot path needs, so no narrowing is
// required. In tests the boot spy conforms to that same existing protocol.

/// Boot reconciliation for the approval fabric — the restart entry point of the single
/// execution locus. It never transitions a run row directly: it cleans terminal-run orphans, then
/// per unresolved approval either re-parks a waiter on the session lane (unexpired PENDING),
/// CAS-expires + signals a denial for the parked waiter to consume (expired PENDING), re-parks
/// under the crash-window belt (APPROVED row on an AWAITING_APPROVAL run), or re-buffers the
/// already-committed denial (REJECTED/EXPIRED row on an AWAITING_APPROVAL run — the deny-side
/// crash window). The parked waiter performs every run transition, owner notice, and button
/// disarm; the reconciler only orchestrates.
public struct ApprovalBootReconciler: Sendable {
  private let approvals: any ApprovalStore
  private let runs: any RunStore

  private let lanes: SessionLaneRegistry
  private let coordinator: ApprovalCoordinator
  private let waiter: any ApprovalParking
  /// This reconciler enqueues onto the lane registry itself rather than through `TurnEnqueuer`, so
  /// it carries the same tail: the waiter it parks drives the run's own terminal transition, and a
  /// deny, expiry or command resolution leaves a deferred receipt only this closure can settle.
  private let settlement: LaneSettlement

  private let now: @Sendable () -> Date

  private let logger: Logger

  public init(
    approvals: any ApprovalStore,
    runs: any RunStore,
    lanes: SessionLaneRegistry,
    coordinator: ApprovalCoordinator,
    waiter: any ApprovalParking,
    learning: (any ScheduledLearningStore)? = nil,
    now: @escaping @Sendable () -> Date,
    logger: Logger
  ) {
    self.approvals = approvals
    self.runs = runs

    self.lanes = lanes
    self.coordinator = coordinator
    self.waiter = waiter
    self.settlement = LaneSettlement(learning: learning, now: now, logger: logger)

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

// MARK: - Claimed-Window Copy

extension ApprovalBootReconciler {
  /// The synthetic observation for an action claimed before a crash — the honest answer is that
  /// the outcome is unknowable, never "it ran" or "it didn't".
  static let claimedCrashObservation =
    "The daemon restarted while this approved action was executing; whether it completed is unknown."

  /// The owner DM for the same window. Tool name only — the canonical target can be arbitrarily
  /// long and this notice is a single outbox row.
  static func claimedCrashNotice(tool: String) -> String {
    "I restarted while running the approved \(tool) action and can't confirm whether it completed — please check before asking again."
  }
}

// MARK: - Per-Row Re-Park

private extension ApprovalBootReconciler {
  /// Triage for an APPROVED row: if the execution claim committed before the crash (the
  /// run left AWAITING_APPROVAL), the external effect may or may not have happened — the store
  /// settles it in place (truthful observation + unconditional owner notice) and nothing parks.
  /// Only a still-parked run returns true and takes the replay belt.
  func approvedRowNeedsReplayPark(_ approval: Approval, now instant: Date) -> Bool {
    let settlement: ClaimedApprovalBootOutcome
    do {
      settlement = try runs.settleClaimedApprovalAtBoot(
        runId: approval.runId,
        observationMessageId: approval.observationMessageId,
        observationContent: Self.claimedCrashObservation,
        noticeChatId: approval.ownerUserId,
        noticeText: Self.claimedCrashNotice(tool: approval.tool),
        now: instant
      )
    } catch {
      logger.error("boot approvals: claimed-window triage failed for \(approval.id): \(error)")
      return false
    }
    switch settlement {
    case .settled:
      logger.warning(
        "boot approvals: settled approval \(approval.id) claimed before the crash (outcome unknown)"
      )
      return false
    case .alreadyResolved:
      logger.debug("boot approvals: approval \(approval.id) already carries its result")
      return false
    case .reparkForReplay:
      return true
    }
  }

  func reparkOne(_ approval: Approval, now instant: Date) async {
    let revalidate: Bool

    switch approval.state {
    case .approved:
      guard approvedRowNeedsReplayPark(approval, now: instant) else {
        return
      }
      // Crash window: granted before the crash, never claimed. Buffer the approval signal and
      // re-park under re-validation so the waiter rechecks policy_version before executing the
      // recorded action.
      await coordinator.signal(approvalId: approval.id, .approved)
      revalidate = true
    case .pending where approval.expiresTs <= instant:
      // Expiry: CAS PENDING→EXPIRED (+ approvalDenied/expired audit) here, then let the parked
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
      // Unexpired: re-park so buttons and the FIFO queue-behind contract survive restart.
      revalidate = false
    case .rejected:
      // Deny-side twin of the crash window: the deny CAS (+ its audit) committed but the
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
    let settle = settlement
    let approvalId = approval.id
    let runId = approval.runId
    let sessionId = approval.sessionId
    let chatId = approval.ownerUserId

    let result = await lanes.enqueue(sessionID: sessionId, runID: runId) {
      await park.park(
        approvalId: approvalId,
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        revalidatePolicyOnApprove: revalidate
      )
      // The same tail `TurnEnqueuer` ends its closure with, for the same reason: the resolution
      // this park waits on can drive the run terminal with a deferred receipt, and nothing else in
      // this process would settle it before the next boot.
      settle.settle(runId: runId)
    }

    if result == .shuttingDown {
      // The daemon began draining mid-reconcile: leave the durable approval untouched so the next
      // boot re-parks it, rather than resolving it against a lane that will never run the waiter.
      logger.notice(
        "boot approvals: approval \(approvalId) not re-parked; lane admission is shutting down"
      )
    }
  }
}
