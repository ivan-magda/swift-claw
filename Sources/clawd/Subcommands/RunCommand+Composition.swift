import AsyncHTTPClient
import ClawAgent
import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawSecrets
import ClawTelegram
import ClawTools
import ClawWorkspace
import Foundation
import Logging

// MARK: - Service Graph Composition

extension RunCommand {
  /// The composition root's cross-cutting inputs — everything `run()` resolves before wiring
  /// (config, secrets, stores, the two HTTP executors, the Telegram transport, and the logger) —
  /// so every `make*` helper draws from one bundle instead of re-threading eight parameters.
  struct DaemonDependencies: Sendable {
    let config: AppConfig
    let secrets: Secrets
    let stores: ClawStores
    let executor: AsyncHTTPExecutor
    let toolExecutor: AsyncHTTPExecutor
    let transport: TelegramClient
    let botUsername: String?
    let logger: Logger
  }

  /// Builds the service graph: the OpenAI-compatible provider + agent feed a `TurnRunner`, which
  /// the router dispatches from the poller. Both Telegram and the LLM share the injected executor.
  func makeDaemon(deps: DaemonDependencies) async -> Daemon {
    let coordination = TurnCoordination()

    // Hoisted so the schedule draft parser and the agent share one provider instance.
    let provider = makeProvider(deps: deps)

    // Hoisted so the agent and the /schedule parse share one offline-first cost resolver — both
    // meter spend against the same price snapshot and reference rate.
    let costResolver = CostResolver(
      priceTable: PriceFileLoader.load(),
      referenceUSDPerToken: deps.config.budget.referenceUSDPerToken
    )

    let workspace = FileSystemWorkspace(
      root: deps.config.stateRoot.appendingPathComponent("workspace", isDirectory: true)
    )
    let agentStack = makeAgentStack(
      deps: deps,
      provider: provider,
      workspace: workspace,
      costResolver: costResolver
    )

    let turnRunner = makeTurnRunner(
      deps: deps,
      coordination: coordination,
      agentStack: agentStack
    )
    let approvalFabric = makeApprovalFabric(
      deps: deps,
      coordination: coordination,
      agentStack: agentStack,
      turnRunner: turnRunner
    )

    let scheduleSurface = makeScheduleSurface(
      config: deps.config,
      stores: deps.stores,
      provider: provider,
      costResolver: costResolver,
      logger: deps.logger
    )
    let (poller, dispatcher) = makeIntakeServices(
      deps: deps,
      coordination: coordination,
      turnRunner: turnRunner,
      scheduleSurface: scheduleSurface,
      approvalCallbacks: approvalFabric.handler
    )
    let (scheduler, heartbeatOwner) = makeScheduler(
      deps: deps,
      coordination: coordination,
      turnRunner: turnRunner,
      workspace: workspace
    )

    return Daemon(
      services: [poller, dispatcher, scheduler, approvalFabric.expiry],
      boot: bootSequence(
        deps: deps,
        coordination: coordination,
        waiter: approvalFabric.waiter,
        heartbeatOwner: heartbeatOwner
      ),
      logger: deps.logger
    )
  }

  func fetchBotUsername(transport: TelegramClient, logger: Logger) async -> String? {
    do {
      return try await transport.getMe().username
    } catch {
      logger.warning(
        "failed to fetch bot identity; command mentions will require bare commands: \(error)"
      )
      return nil
    }
  }
}

// MARK: - Turn & Intake Wiring

private extension RunCommand {
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

  /// The Task-16 approve-resume fabric: the callback handler that answers an owner's tap, the
  /// waiter (the single execution locus, §5.5), and the expiry sweeper.
  struct ApprovalFabric {
    let handler: ApprovalCallbackHandler
    let waiter: ApprovalWaiter
    let expiry: ApprovalExpiryService
  }

  func makeProvider(deps: DaemonDependencies) -> OpenAICompatibleProvider {
    OpenAICompatibleProvider(
      config: deps.config.llm.withAPIKey(deps.secrets.llmApiKey ?? ""),
      http: deps.executor,
      sleep: { try await Task.sleep(for: .seconds($0)) },
      jitter: { Double.random(in: 0...$0) },
      logger: deps.logger
    )
  }

  func makeTurnRunner(
    deps: DaemonDependencies,
    coordination: TurnCoordination,
    agentStack: AgentStack
  ) -> TurnRunner {
    let outboxSignal = coordination.outboxSignal
    return TurnRunner(
      sessionMessages: deps.stores.sessionMessages,
      runs: deps.stores.runs,
      usageStore: deps.stores.usage,
      audit: deps.stores.audit,
      agent: agentStack.agent,
      budget: deps.config.budget,
      contextBuilder: agentStack.contextBuilder,
      pendingConfirmations: coordination.pendingConfirmations,
      notifyOutbox: { outboxSignal.poke() },
      breaker: BudgetBreaker(budget: deps.config.budget),
      delivery: deps.transport,
      parker: coordination.deferredParker,
      approvalExpirySeconds: deps.config.approvalExpirySeconds,
      logger: deps.logger
    )
  }

  /// Builds the executor (recorded-args execution) and the waiter, adopted into the deferred
  /// parker to close the `turnRunner` ⇄ `approvalWaiter` construction cycle, and the Task-15
  /// callback handler that answers an owner's tap into it.
  func makeApprovalFabric(
    deps: DaemonDependencies,
    coordination: TurnCoordination,
    agentStack: AgentStack,
    turnRunner: TurnRunner
  ) -> ApprovalFabric {
    let contextBuilder = agentStack.contextBuilder
    let approvedExecutor = ApprovedActionExecutor(
      tools: agentStack.toolDispatcher.toolsByName,
      runs: deps.stores.runs,
      now: { Date() },
      logger: deps.logger
    )
    let approvalWaiter = ApprovalWaiter(
      approvals: deps.stores.approvals,
      runs: deps.stores.runs,
      coordinator: coordination.approvalCoordinator,
      executor: approvedExecutor,
      turns: turnRunner,
      delivery: deps.transport,
      callbacks: deps.transport,
      currentPolicyVersion: { contextBuilder.currentPolicyVersion() },
      now: { Date() },
      logger: deps.logger
    )
    coordination.deferredParker.adopt(approvalWaiter)

    let handler = ApprovalCallbackHandler.make(
      processed: deps.stores.processed,
      delivery: deps.transport,
      accessControl: AccessControl(allowlist: deps.stores.allowlist),
      approvals: deps.stores.approvals,
      audit: deps.stores.audit,
      coordinator: coordination.approvalCoordinator,
      callbacks: deps.transport,
      currentPolicyVersion: { contextBuilder.currentPolicyVersion() },
      now: { Date() },
      logger: deps.logger
    )
    let expiry = ApprovalExpiryService(
      approvals: deps.stores.approvals,
      coordinator: coordination.approvalCoordinator,
      now: { Date() },
      sleep: { try await Task.sleep(for: $0) },
      logger: deps.logger
    )
    // The real waiter is returned so boot re-park (spec §7) parks the SAME instance the callback
    // path resumes — one execution locus across suspend, callback, and restart.
    return ApprovalFabric(handler: handler, waiter: approvalWaiter, expiry: expiry)
  }

  /// Builds the `/schedule` surface: the budget-gated, deadline-bounded draft parser (sharing the
  /// daemon's provider and cost resolver so its ONE LLM call meters spend like a turn), the
  /// deterministic validator, and the read/claim stores. Extracted from `makeDaemon` so the parser's
  /// spend-discipline wiring reads in one place.
  func makeScheduleSurface(
    config: AppConfig,
    stores: ClawStores,
    provider: OpenAICompatibleProvider,
    costResolver: CostResolver,
    logger: Logger
  ) -> ScheduleSurface {
    ScheduleSurface(
      parser: ScheduleDraftParser(
        provider: provider,
        model: config.llm.model,
        usageStore: stores.usage,
        budget: config.budget,
        costResolver: costResolver,
        sleep: { try await Task.sleep(for: $0) },
        logger: logger
      ),
      validator: ScheduleDraftValidator(
        minIntervalMinutes: config.schedMinIntervalMinutes,
        defaultTimezone: config.timezone
      ),
      calculator: OccurrenceCalculator(),
      jobs: stores.scheduledJobs,
      commands: stores.scheduleCommands
    )
  }

  /// Wires the inbound/outbound message services: the router that dispatches updates, the poller
  /// that feeds it, and the outbox dispatcher the turn runner pokes via the shared signal.
  func makeIntakeServices(
    deps: DaemonDependencies,
    coordination: TurnCoordination,
    turnRunner: TurnRunner,
    scheduleSurface: ScheduleSurface,
    approvalCallbacks: ApprovalCallbackHandler
  ) -> (poller: TelegramPollerService, dispatcher: OutboxDispatcher) {
    let router = MessageRouter(
      processed: deps.stores.processed,
      sessionMessages: deps.stores.sessionMessages,
      commands: deps.stores.commands,
      memory: deps.stores.memory,
      memoryCommands: deps.stores.memoryCommands,
      pendingConfirmations: coordination.pendingConfirmations,
      botUsername: deps.botUsername,
      accessControl: AccessControl(allowlist: deps.stores.allowlist),
      delivery: deps.transport,
      turnRunner: turnRunner,
      lanes: coordination.lanes,
      schedule: scheduleSurface,
      approvalCallbacks: approvalCallbacks,
      coordinator: coordination.approvalCoordinator,
      logger: deps.logger
    )
    let poller = TelegramPollerService(
      intake: deps.transport,
      router: router,
      cursor: deps.stores.cursor,
      pollTimeout: deps.config.pollTimeoutSeconds,
      logger: deps.logger
    )
    let dispatcher = OutboxDispatcher(
      outbox: deps.stores.outbox,
      delivery: deps.transport,
      signal: coordination.outboxSignal,
      logger: deps.logger
    )
    return (poller: poller, dispatcher: dispatcher)
  }

  /// Resolves the heartbeat settings bundle once from config and builds the scheduler around it.
  /// The owner chat id also threads to boot reconcile (spec §12/A6): a crashed heartbeat run's
  /// synthetic session key carries no chat id, so its crash notice can only reach the owner via
  /// this config-derived target.
  func makeScheduler(
    deps: DaemonDependencies,
    coordination: TurnCoordination,
    turnRunner: TurnRunner,
    workspace: FileSystemWorkspace
  ) -> (scheduler: SchedulerService, heartbeatOwner: Int64?) {
    let heartbeatSettings = HeartbeatSettings.resolve(config: deps.config)
    let scheduler = SchedulerService(
      jobs: deps.stores.scheduledJobs,
      lanes: coordination.lanes,
      turns: turnRunner,
      calculator: OccurrenceCalculator(),
      catchUpMaxAge: .seconds(Int64(deps.config.schedCatchUpMaxAgeMinutes) * 60),
      heartbeat: heartbeatSettings,
      workspace: workspace,
      audit: deps.stores.audit,
      now: { Date() },
      sleep: { try await Task.sleep(for: $0) },
      logger: deps.logger
    )
    return (scheduler, heartbeatSettings.ownerChatId)
  }
}

// MARK: - Agent Stack Assembly

private extension RunCommand {
  /// The tool-gated agent stack `makeAgentStack` assembles: the policy-gated dispatcher, the
  /// `AgentRuntime`, and the context builder that folds the static sub-hash into `policy_version`.
  struct AgentStack {
    let toolDispatcher: GatedToolDispatcher
    let agent: AgentRuntime
    let contextBuilder: ContextBuilder
  }

  func makeAgentStack(
    deps: DaemonDependencies,
    provider: OpenAICompatibleProvider,
    workspace: FileSystemWorkspace,
    costResolver: CostResolver
  ) -> AgentStack {
    let toolDispatcher = makeToolDispatcher(
      secrets: deps.secrets,
      workspace: workspace,
      toolExecutor: deps.toolExecutor
    )
    let staticSubhash = policyStaticSubhash(
      toolDispatcher: toolDispatcher,
      config: deps.config,
      secrets: deps.secrets,
      workspace: workspace
    )
    let agent = makeAgent(
      deps: deps,
      provider: provider,
      toolDispatcher: toolDispatcher,
      costResolver: costResolver
    )
    let contextBuilder = makeContextBuilder(
      config: deps.config,
      workspace: workspace,
      stores: deps.stores,
      policyStaticSubhash: staticSubhash,
      logger: deps.logger
    )
    return AgentStack(toolDispatcher: toolDispatcher, agent: agent, contextBuilder: contextBuilder)
  }

  /// Assembles the v1 tool catalog behind its policy gate (§7/§9). Tool fetches use the dedicated
  /// no-redirect `toolExecutor` (§7.2); no `searchApiKey` ⇒ `web_search` is never constructed
  /// (unconfigured ⇒ absent, §7.3). Tier-3 private texts load from DISK at gate-evaluation time
  /// (rev.1 H1), not the assembly snapshot, so the loader closure re-reads the workspace each call.
  func makeToolDispatcher(
    secrets: Secrets,
    workspace: FileSystemWorkspace,
    toolExecutor: AsyncHTTPExecutor
  ) -> GatedToolDispatcher {
    let secretValues = secrets.redactionValues
    let redactor = SecretRedactor(secretValues: secretValues)

    var tools: [any Tool] = [
      FileReadTool(workspaceRoot: workspace.root, redactor: redactor),
      FileWriteTool(workspaceRoot: workspace.root, redactor: redactor),
      WebFetchTool(http: toolExecutor, resolver: SystemAddressResolver(), redactor: redactor),
    ]

    if let searchApiKey = secrets.searchApiKey {
      tools.append(
        WebSearchTool(search: ExaSearchProvider(apiKey: searchApiKey, http: toolExecutor))
      )
    }

    let privateFileLoader: @Sendable () -> [String] = {
      [WorkspaceFile.memory, WorkspaceFile.user].compactMap { file in
        try? String(
          contentsOf: workspace.root.appendingPathComponent(file.relativePath),
          encoding: .utf8
        )
      }
    }

    return GatedToolDispatcher(
      registry: ToolRegistry(tools: tools),
      gate: ToolPolicyGate(
        argGuard: ExfilArgGuard(secretValues: secretValues),
        privateFileLoader: privateFileLoader
      )
    )
  }

  /// §3.2 static sub-hash (classes 2–3): the same tool surface the gate enforces, plus the pinned
  /// egress/policy config. Secret values are never hashed — only the base URL, search presence,
  /// and workspace root identity. Injected into `ContextBuilder`, which folds in the class-1 prompt
  /// materials and returns the combined `policy_version`.
  func policyStaticSubhash(
    toolDispatcher: GatedToolDispatcher,
    config: AppConfig,
    secrets: Secrets,
    workspace: FileSystemWorkspace
  ) -> String {
    PolicyFingerprint.staticSubhash(
      tools: toolDispatcher.definitions,
      llmBaseURL: config.llm.baseURL,
      searchEndpointPresent: secrets.searchApiKey != nil,
      workspaceRoot: workspace.root.path
    )
  }

  /// Builds the grapheme-budgeted context assembler, injected with the composition root's static
  /// policy sub-hash (§3.2) so `contextBuilder.currentPolicyVersion()` reflects the real tool/config
  /// surface, not a test default.
  func makeContextBuilder(
    config: AppConfig,
    workspace: FileSystemWorkspace,
    stores: ClawStores,
    policyStaticSubhash: String,
    logger: Logger
  ) -> ContextBuilder {
    let contextBudget = ContextBudget(
      inputCapGraphemes: TokenEstimator.graphemeBudget(
        forInputTokens: config.budget.maxInputTokens
      ),
      userFileCap: ContextBudget.default.userFileCap,
      memoryFileCap: ContextBudget.default.memoryFileCap,
      itemsCap: ContextBudget.default.itemsCap,
      historyCap: ContextBudget.default.historyCap,
      recallCap: ContextBudget.default.recallCap,
      skillsCap: ContextBudget.default.skillsCap,
      recallHitCap: ContextBudget.default.recallHitCap
    )
    return ContextBuilder(
      systemPrompt: SystemPrompt.minimal,
      workspace: workspace,
      memoryStore: stores.memory,
      retriever: stores.retriever,
      budget: contextBudget,
      policyStaticSubhash: policyStaticSubhash,
      warn: { warning in logger.warning("\(warning)") }
    )
  }

  /// Assembles the LLM agent stack: the OpenAI-compatible provider, the injected offline-first cost
  /// resolver (shared with the /schedule parse), and the `AgentRuntime` that orchestrates one turn.
  /// Kept separate from the service wiring so the composition root reads as "build the agent → feed
  /// the turn runner → register the services".
  func makeAgent(
    deps: DaemonDependencies,
    provider: OpenAICompatibleProvider,
    toolDispatcher: GatedToolDispatcher,
    costResolver: CostResolver
  ) -> AgentRuntime {
    AgentRuntime(
      provider: provider,
      typingIndicator: TelegramTypingIndicator(transport: deps.transport),
      draftStreamer: TelegramRichDraftStreamer(transport: deps.transport),
      streamingEnabled: deps.config.llm.streamingEnabled,
      costResolver: costResolver,
      budget: deps.config.budget,
      model: deps.config.llm.model,
      toolDispatcher: toolDispatcher,
      usageStore: deps.stores.usage,
      auditLog: deps.stores.audit,
      logger: deps.logger,
      sleep: { try await Task.sleep(for: $0) }
    )
  }
}

// MARK: - Boot Sequence

private extension RunCommand {
  /// Composes the daemon's one-shot boot reconciliation: register the command menu with Telegram
  /// (`registerMenu`), sweep crash-orphaned runs (`reconcileRuns`, F22), then re-park unresolved
  /// approvals (`reconcileApprovals`, §7). Each step is best-effort, but `reconcileApprovals` is
  /// deliberately last: the run sweep must fail its orphans first so the approval sweep only sees
  /// runs that are genuinely still parked. All three run before any update is served.
  func bootSequence(
    deps: DaemonDependencies,
    coordination: TurnCoordination,
    waiter: ApprovalWaiter,
    heartbeatOwner: Int64?
  ) -> @Sendable () async -> Void {
    let registerMenu = registerMenuCommands(transport: deps.transport, logger: deps.logger)
    let reconcileRuns = bootReconcile(
      stores: deps.stores,
      heartbeatOwner: heartbeatOwner,
      logger: deps.logger
    )
    let reconcileApprovals = bootReconcileApprovals(
      stores: deps.stores,
      lanes: coordination.lanes,
      coordinator: coordination.approvalCoordinator,
      waiter: waiter,
      logger: deps.logger
    )
    return {
      await registerMenu()
      await reconcileRuns()
      await reconcileApprovals()
    }
  }

  /// Builds the boot step that registers the command menu with Telegram. This is a reconciliation:
  /// `setMyCommands` writes persistent server-side state, so re-declaring on every boot keeps the
  /// registered picker in sync with this build's `botMenuCommands`. Best-effort — a failure only
  /// means the picker is stale, never that the bot can't serve.
  func registerMenuCommands(
    transport: any TelegramTransport,
    logger: Logger
  ) -> @Sendable () async -> Void {
    {
      do {
        try await transport.setMyCommands(
          [
            BotMenuCommand(command: "start", description: "Start the bot."),
            BotMenuCommand(command: "new", description: "Start a new session."),
            BotMenuCommand(command: "stop", description: "Stop the current run."),
            BotMenuCommand(command: "remember", description: "Save a memory."),
            BotMenuCommand(command: "memory", description: "Review saved memories."),
            BotMenuCommand(command: "schedule", description: "Create or list schedules."),
            BotMenuCommand(command: "pause", description: "Pause a schedule."),
            BotMenuCommand(command: "resume", description: "Resume a paused schedule."),
            BotMenuCommand(command: "runnow", description: "Run a schedule now."),
            BotMenuCommand(command: "cancel", description: "Cancel a schedule."),
            BotMenuCommand(command: "help", description: "Show commands and confirm rules."),
          ]
        )
      } catch {
        logger.warning("setMyCommands failed: \(error)")
      }
    }
  }

  /// The boot step that sweeps any run left RUNNING by a crash to FAILED and enqueues a degradation
  /// reply, so a turn interrupted mid-flight is never silent (F22). It runs before the services
  /// serve, so the dispatcher's boot drain delivers whatever this enqueues.
  func bootReconcile(
    stores: ClawStores,
    heartbeatOwner: Int64?,
    logger: Logger
  ) -> @Sendable () async -> Void {
    {
      do {
        let replies = try stores.runs.reconcileRunsAtBoot(
          now: Date(),
          degradationText: Degradation.unfinished,
          heartbeatNoticeChatId: heartbeatOwner
        )
        if !replies.isEmpty {
          logger.warning(
            "boot reconcile: \(replies.count) unfinished run(s) → degradation enqueued"
          )
        }
      } catch {
        logger.error("boot reconcile failed: \(error)")
      }
    }
  }

  /// The boot step that re-establishes the approval fabric after a restart (spec §7): terminal-run
  /// PENDING rows are cleaned, unexpired parked approvals are re-parked on their lanes so buttons and
  /// the FIFO queue-behind contract survive restart (§5.5), expired ones are swept to DENY→FAILED
  /// (§6.4), and an APPROVED row left by a crash between grant and execution is resumed under the
  /// §6.5 re-validation belt. Runs before the services serve, so the re-parked lanes are live before
  /// the first callback arrives.
  func bootReconcileApprovals(
    stores: ClawStores,
    lanes: SessionLaneRegistry,
    coordinator: ApprovalCoordinator,
    waiter: ApprovalWaiter,
    logger: Logger
  ) -> @Sendable () async -> Void {
    let reconciler = ApprovalBootReconciler(
      approvals: stores.approvals,
      lanes: lanes,
      coordinator: coordinator,
      waiter: waiter,
      now: { Date() },
      logger: logger
    )
    return {
      await reconciler.reconcile()
    }
  }
}
