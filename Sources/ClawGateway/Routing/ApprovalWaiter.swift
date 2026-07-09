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
      guard let approval = loadApproval(approvalId) else {
        // The nonce is never consumed, so a nil row means a resolver already drove the run
        // terminal; the durable state is settled and the lane is free.
        logger.debug("approval \(approvalId) absent at deny resume; nothing to finalize")
        return
      }
      await resolveDenied(approval: approval, decision: decision, chatId: chatId)
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

// MARK: - Deny Half (§6.4)

extension ApprovalWaiter {
  /// The §6.4 deny/cancel/expiry half: the resolver (callback handler, ticker, `/stop`//`new`, or
  /// boot sweep) has ALREADY CAS'd the row and signalled the coordinator (D3 — the audit rode that
  /// CAS). The waiter — the single execution locus (§5.5) — now (1) fills the placeholder
  /// observation in place so history never holds a dangling tool_call, (2) drives the run to its
  /// terminal state, (3) sends the plain-language owner notice for a reject/expiry (the `/stop`//
  /// `new` command already acked the owner), and (4) disarms the buttons. Steps 3–4 are best-effort
  /// transport over already-committed durable state — a transport failure must not strand the lane.
  func resolveDenied(
    approval: Approval,
    decision: ApprovalDecision,
    chatId: Int64
  ) async {
    let cancel: CancelReason? =
      switch decision {
      case .cancelled: .cancelled
      case .superseded: .superseded
      case .rejected, .expired, .stalePolicy: nil
      }

    do {
      _ = try runs.resolveDeniedObservation(
        runId: approval.runId,
        observationMessageId: approval.observationMessageId,
        content: Self.deniedObservationContent(for: decision),
        cancel: cancel,
        now: now()
      )
    } catch {
      logger.error("approval \(approval.id) deny-observation commit failed: \(error)")
    }

    if cancel == nil {
      _ = try? await delivery.sendMessage(
        chatId: chatId,
        text: Self.ownerNotice(for: decision)
      )
    }

    if let promptMessageId = approval.promptMessageId {
      try? await callbacks.editMessageReplyMarkup(
        chatId: chatId,
        messageId: promptMessageId,
        replyMarkup: nil
      )
    }
  }
}

// MARK: - Deny Copy

private extension ApprovalWaiter {
  /// The synthetic tool-observation content (§6.4) — what the model sees for the un-run call, so
  /// the next assembly explains the missing result instead of exposing a dangling proposal.
  static func deniedObservationContent(for decision: ApprovalDecision) -> String {
    switch decision {
    case .rejected: "The owner declined this action."
    case .expired: "The approval expired before the owner responded."
    case .cancelled: "Cancelled by /stop."
    case .superseded: "Superseded by /new."
    case .stalePolicy: "The approval was voided because the policy changed before it ran."
    }
  }

  /// The plain-language owner DM for a reject/expiry (§6.4). Cancel/supersede are covered by the
  /// `/stop`//`new` command ack, so no notice is sent for those.
  static func ownerNotice(for decision: ApprovalDecision) -> String {
    switch decision {
    case .expired: "That approval expired, so I didn't run the action."
    case .stalePolicy: "I didn't run that action — the configuration changed after I asked."
    case .rejected, .cancelled, .superseded: "Understood — I won't run that action."
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
