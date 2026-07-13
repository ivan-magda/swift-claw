import ClawAgent
import ClawCore
import ClawGateway
import ClawTelegram
import ClawTools
import Foundation

// MARK: - Coordination Fixtures & Approve-Resume Fabric

extension DaemonBuilder {
  /// The shared in-process coordination fixtures, created before any service so every consumer
  /// references the SAME instances: the outbox signal is created before the `TurnRunner` so its
  /// `notifyOutbox` closure can capture it (each commit pokes the dispatcher to drain the rows it
  /// just enqueued), and the parker/coordinator pair closes the approve-resume loop.
  struct TurnCoordination: Sendable {
    let outboxSignal = OutboxSignal()
    let lanes = SessionLaneRegistry()
    let pendingConfirmations = PendingConfirmationRegistry()

    let approvalCoordinator = ApprovalCoordinator()
    let deferredParker = DeferredApprovalParker()
  }

  /// The approve-resume fabric: the callback handler that answers an owner's tap, the waiter
  /// (the single execution locus), and the expiry sweeper.
  struct ApprovalFabric {
    let handler: ApprovalCallbackHandler
    let waiter: ApprovalWaiter
    let expiry: ApprovalExpiryService
  }

  func makeTurnRunner(coordination: TurnCoordination, agentStack: AgentStack) -> TurnRunner {
    let outboxSignal = coordination.outboxSignal
    return TurnRunner(
      sessionMessages: stores.sessionMessages,
      runs: stores.runs,
      usageStore: stores.usage,
      audit: stores.audit,
      agent: agentStack.agent,
      budget: config.budget,
      contextBuilder: agentStack.contextBuilder,
      notifyOutbox: { outboxSignal.poke() },
      breaker: BudgetBreaker(budget: config.budget),
      delivery: transport,
      parker: coordination.deferredParker,
      approvalExpirySeconds: config.approvalExpirySeconds,
      logger: logger
    )
  }

  /// Builds the executor (recorded-args execution) and the waiter, adopted into the deferred
  /// parker to close the `turnRunner` ⇄ `approvalWaiter` construction cycle, and the callback
  /// handler that answers an owner's tap into it.
  func makeApprovalFabric(
    coordination: TurnCoordination,
    agentStack: AgentStack,
    turnRunner: TurnRunner
  ) -> ApprovalFabric {
    let contextBuilder = agentStack.contextBuilder
    let argumentGuard = ExfilArgGuard(secretValues: secrets.redactionValues)
    let approvedExecutor = ApprovedActionExecutor(
      tools: agentStack.toolDispatcher.toolsByName,
      runs: stores.runs,
      redactArguments: { arguments in
        argumentGuard.renderRedacted(argsJSON: arguments)
      },
      now: { Date() },
      logger: logger
    )
    let approvalWaiter = ApprovalWaiter(
      approvals: stores.approvals,
      runs: stores.runs,
      coordinator: coordination.approvalCoordinator,
      executor: approvedExecutor,
      turns: turnRunner,
      delivery: transport,
      callbacks: transport,
      typing: TelegramTypingIndicator(transport: transport),
      clock: ContinuousClock(),
      currentPolicyVersion: { contextBuilder.currentPolicyVersion() },
      now: { Date() },
      logger: logger
    )
    coordination.deferredParker.adopt(approvalWaiter)

    let handler = ApprovalCallbackHandler.make(
      processed: stores.processed,
      delivery: transport,
      accessControl: AccessControl(allowlist: stores.allowlist),
      approvals: stores.approvals,
      audit: stores.audit,
      coordinator: coordination.approvalCoordinator,
      callbacks: transport,
      currentPolicyVersion: { contextBuilder.currentPolicyVersion() },
      now: { Date() },
      logger: logger
    )
    let expiry = ApprovalExpiryService(
      approvals: stores.approvals,
      coordinator: coordination.approvalCoordinator,
      now: { Date() },
      clock: ContinuousClock(),
      logger: logger
    )
    // The real waiter is returned so boot re-park parks the SAME instance the callback
    // path resumes — one execution locus across suspend, callback, and restart.
    return ApprovalFabric(handler: handler, waiter: approvalWaiter, expiry: expiry)
  }
}
