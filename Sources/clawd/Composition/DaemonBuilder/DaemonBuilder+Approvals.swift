import ClawAgent
import ClawCore
import ClawGateway
import ClawTelegram
import ClawTools
import Foundation

// MARK: - Coordination Fixtures & Approve-Resume Fabric

extension DaemonBuilder {
  struct TurnCoordination: Sendable {
    let outboxSignal = OutboxSignal()
    let lanes = SessionLaneRegistry()
    let pendingConfirmations = PendingConfirmationRegistry()

    let approvalCoordinator = ApprovalCoordinator()
    let deferredParker = DeferredApprovalParker()
  }

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
      breaker: BudgetBreaker(budget: config.budget, costPolicy: costPolicy),
      delivery: transport,
      ownerChatId: config.heartbeatOwnerChatId,
      now: now,
      freezeLearningSurface: freezeLearningSurface,
      learning: makePinnedLessonStore(),
      parker: coordination.deferredParker,
      approvalExpirySeconds: config.approvalExpirySeconds,
      logger: logger
    )
  }

  func makeApprovalCallbackHandler(
    coordination: TurnCoordination,
    agentStack: AgentStack,
    conferenceProfile: Bool = false
  ) -> ApprovalCallbackHandler {
    let contextBuilder = agentStack.contextBuilder
    return ApprovalCallbackHandler.make(
      processed: stores.processed,
      delivery: transport,
      accessControl: AccessControl(
        allowlist: stores.allowlist,
        groupChats: config.groupChats,
        conferenceProfile: conferenceProfile
      ),
      approvals: stores.approvals,
      runs: stores.runs,
      membership: transport,
      audit: stores.audit,
      coordinator: coordination.approvalCoordinator,
      callbacks: transport,
      currentPolicyVersion: { contextBuilder.currentPolicyVersion() },
      now: { Date() },
      logger: logger
    )
  }

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
    return ApprovalFabric(waiter: approvalWaiter, expiry: expiry)
  }
}
