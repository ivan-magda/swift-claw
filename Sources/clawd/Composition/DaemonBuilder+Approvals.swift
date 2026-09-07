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

  /// The approve-resume fabric: the waiter (the single execution locus) and the expiry sweeper.
  /// The callback handler is built separately because it needs no `TurnRunner` while the router
  /// does, so it has to exist before the router that carries it.
  struct ApprovalFabric {
    let waiter: ApprovalWaiter
    let expiry: ApprovalExpiryService
  }

  func makeTurnRunner(
    coordination: TurnCoordination,
    agentStack: AgentStack,
    costPolicy: LLMCostPolicy,
    imageCache: ImageCache,
    freezeLearningSurface: @escaping @Sendable (Int64, String) -> Void
  ) -> TurnRunner {
    let outboxSignal = coordination.outboxSignal
    return TurnRunner(
      sessionMessages: stores.sessionMessages,
      runs: stores.runs,
      usageStore: stores.usage,
      audit: stores.audit,
      agent: agentStack.agent,
      budget: config.budget,
      contextBuilder: agentStack.contextBuilder,
      imageCache: imageCache,
      notifyOutbox: { outboxSignal.poke() },
      // The resolved route's billing, not the init default: a subscription route must not fire a
      // daily USD-cap DM against dollars earlier metered usage rang up.
      breaker: BudgetBreaker(budget: config.budget, costPolicy: costPolicy),
      delivery: transport,
      ownerChatId: config.heartbeatOwnerChatId,
      freezeLearningSurface: freezeLearningSurface,
      learning: makePinnedLessonStore(),
      parker: coordination.deferredParker,
      approvalExpirySeconds: config.approvalExpirySeconds,
      logger: logger
    )
  }

  /// The store the turn path reads a bound run's pinned lessons through, or nil when
  /// `CLAW_LEARNING_ENABLED` is unset. Gated here, not left to the fire path having written no
  /// binding: a run bound while the flag was on can be parked on an approval, survive a restart
  /// that removed the flag, and resume — boot reconciliation deliberately leaves AWAITING_APPROVAL
  /// runs alone. A disarmed daemon therefore has to refuse the read itself.
  func makePinnedLessonStore() -> (any ScheduledLearningStore)? {
    guard config.learningEnabled else {
      return nil
    }
    return stores.learning
  }

  /// The handler that answers an owner's approve/deny tap. It reaches the router, so it is built
  /// ahead of the router it answers into.
  func makeApprovalCallbackHandler(
    coordination: TurnCoordination,
    agentStack: AgentStack
  ) -> ApprovalCallbackHandler {
    let contextBuilder = agentStack.contextBuilder
    return ApprovalCallbackHandler.make(
      processed: stores.processed,
      delivery: transport,
      accessControl: AccessControl(allowlist: stores.allowlist, groupChats: []),
      approvals: stores.approvals,
      audit: stores.audit,
      coordinator: coordination.approvalCoordinator,
      callbacks: transport,
      currentPolicyVersion: { contextBuilder.currentPolicyVersion() },
      now: { Date() },
      logger: logger
    )
  }

  /// Builds the executor (recorded-args execution) and the waiter, adopted into the deferred
  /// parker to close the `turnRunner` ⇄ `approvalWaiter` construction cycle.
  func makeApprovalFabric(
    coordination: TurnCoordination,
    agentStack: AgentStack,
    turnRunner: TurnRunner
  ) -> ApprovalFabric {
    let contextBuilder = agentStack.contextBuilder
    let argumentGuard = ExfilArgGuard(secretValues: redactionValues)
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

    let expiry = ApprovalExpiryService(
      approvals: stores.approvals,
      coordinator: coordination.approvalCoordinator,
      now: { Date() },
      clock: ContinuousClock(),
      logger: logger
    )
    // The real waiter is returned so boot re-park parks the SAME instance the callback
    // path resumes — one execution locus across suspend, callback, and restart.
    return ApprovalFabric(waiter: approvalWaiter, expiry: expiry)
  }
}
