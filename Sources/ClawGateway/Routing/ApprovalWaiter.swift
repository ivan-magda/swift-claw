import ClawCore
import Foundation
import Logging

/// The single execution locus (§5.5): the parked task that turns a coordinator resolution signal
/// into the §6.3 approve resume or the §6.4 deny finalization. Resolvers (callback handler, ticker,
/// command path) only CAS the durable row and `signal` the coordinator; the waiter — always running
/// on the session lane via `SessionActor.enqueue`, at suspend time (Task 14) and boot re-park
/// (Task 19) — performs the observation update, run transition, owner notice, and button disarm.
///
/// Conforms to the Task-14 `ApprovalParking` seam (which refines `Sendable`) so `TurnRunner` can
/// hold it as `parker`; the `park` signature is exactly the protocol requirement.
public struct ApprovalWaiter: ApprovalParking {
  private let approvals: any ApprovalStore
  private let runs: any RunStore
  private let coordinator: ApprovalCoordinator
  private let executor: any ApprovedActionExecuting
  private let turns: any TurnDispatching
  private let delivery: any MessageDelivery
  private let callbacks: any CallbackResponding
  private let currentPolicyVersion: @Sendable () throws -> String
  private let now: @Sendable () -> Date
  private let logger: Logger

  public init(
    approvals: any ApprovalStore,
    runs: any RunStore,
    coordinator: ApprovalCoordinator,
    executor: any ApprovedActionExecuting,
    turns: any TurnDispatching,
    delivery: any MessageDelivery,
    callbacks: any CallbackResponding,
    currentPolicyVersion: @escaping @Sendable () throws -> String,
    now: @escaping @Sendable () -> Date,
    logger: Logger
  ) {
    self.approvals = approvals
    self.runs = runs
    self.coordinator = coordinator
    self.executor = executor
    self.turns = turns
    self.delivery = delivery
    self.callbacks = callbacks
    self.currentPolicyVersion = currentPolicyVersion
    self.now = now
    self.logger = logger
  }

  /// Awaits the coordinator resolution (buffered if it already landed), then runs the resume/deny
  /// steps. `revalidatePolicyOnApprove` is true ONLY for the §6.5 boot crash-window re-park.
  public func park(
    approvalId: Int64,
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    revalidatePolicyOnApprove: Bool
  ) async {
    guard let signal = await coordinator.awaitResolution(approvalId: approvalId) else {
      // Cancelled while parked (graceful shutdown / lane cancel) with no resolution: exit cleanly.
      // The durable approval row is untouched; Task 19 boot re-park rebuilds the hold on restart.
      logger.debug("approval \(approvalId) park cancelled before resolution; exiting cleanly")
      return
    }
    switch signal {
    case .approved:
      await resolveApproved(
        approvalId: approvalId,
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        revalidatePolicyOnApprove: revalidatePolicyOnApprove
      )
    case .denied(let decision):
      await resolveDenied(
        approvalId: approvalId,
        runId: runId,
        chatId: chatId,
        decision: decision
      )
    }
  }
}

// MARK: - Approve Resume

private extension ApprovalWaiter {
  func resolveApproved(
    approvalId: Int64,
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    revalidatePolicyOnApprove: Bool
  ) async {
    guard let approval = loadApproval(approvalId), approval.state == .approved else {
      logger.warning("approval \(approvalId) was not APPROVED at resume; skipping")
      return
    }

    if revalidatePolicyOnApprove, policyStillMatches(approval) == false {
      await failOnStalePolicy(approval, chatId: chatId)
      return
    }

    let outcome = await executor.executeApproved(approval)
    guard outcome.commit == .committed else {
      // A duplicate signal already resumed the run; do not run the continuation twice.
      logger.debug("approved resume for run \(runId) was a no-op (\(outcome.commit))")
      await disarm(approval, chatId: chatId)
      return
    }

    await turns.resume(
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      contextBoundMessageId: approval.observationMessageId
    )
    await disarm(approval, chatId: chatId)
  }

  func policyStillMatches(_ approval: Approval) -> Bool {
    do {
      return try currentPolicyVersion() == approval.policyVersion
    } catch {
      logger.error("policy recompute failed at resume for run \(approval.runId): \(error)")
      return false  // fail closed
    }
  }

  func failOnStalePolicy(_ approval: Approval, chatId: Int64) async {
    do {
      _ = try runs.failRunStalePolicy(
        runId: approval.runId,
        sessionId: approval.sessionId,
        now: now()
      )
    } catch {
      logger.error("failRunStalePolicy failed for run \(approval.runId): \(error)")
    }
    await notifyOwner(chatId: chatId, text: Self.stalePolicyNotice)
    await disarm(approval, chatId: chatId)
  }
}

// MARK: - Deny Finalization (Task 17 replaces the body)

private extension ApprovalWaiter {
  /// Task 17 owns the deny half: it replaces this body with `resolveDeniedObservation` (the
  /// synthetic in-place observation + cancel/supersede run states + decision-specific copy). This
  /// increment guarantees only the lane-freeing contract: the run fails, the owner is told, the
  /// keyboard is disarmed — so a `.denied` signal never leaves the lane hung.
  func resolveDenied(
    approvalId: Int64,
    runId: Int64,
    chatId: Int64,
    decision: ApprovalDecision
  ) async {
    guard let approval = loadApproval(approvalId) else {
      return
    }
    do {
      // No-op when the run is already CANCELLED/SUPERSEDED (the command path won first); fails an
      // AWAITING_APPROVAL run for reject/expiry.
      try runs.failRun(runId: runId, now: now())
    } catch {
      logger.error("failRun after denial failed for run \(runId): \(error)")
    }
    await notifyOwner(chatId: chatId, text: Self.denialNotice(for: decision))
    await disarm(approval, chatId: chatId)
  }

  static func denialNotice(for decision: ApprovalDecision) -> String {
    switch decision {
    case .rejected: "Okay — I won't do that."
    case .expired: "That approval expired, so I didn't do it."
    case .cancelled: "Cancelled."
    case .superseded: "Starting fresh — I dropped the pending action."
    case .stalePolicy: "My instructions or tools changed, so I didn't run that."
    }
  }
}

// MARK: - Shared Side Effects

private extension ApprovalWaiter {
  static let stalePolicyNotice =
    "My instructions or tools changed since you were asked, so I can't run that now — please re-run."

  func loadApproval(_ id: Int64) -> Approval? {
    do {
      return try approvals.approval(id: id)
    } catch {
      logger.error("approval \(id) load failed: \(error)")
      return nil
    }
  }

  func notifyOwner(chatId: Int64, text: String) async {
    _ = try? await delivery.sendMessage(chatId: chatId, text: text)
  }

  func disarm(_ approval: Approval, chatId: Int64) async {
    guard let promptMessageId = approval.promptMessageId else {
      return
    }
    try? await callbacks.editMessageReplyMarkup(
      chatId: chatId,
      messageId: promptMessageId,
      replyMarkup: nil
    )
  }
}
