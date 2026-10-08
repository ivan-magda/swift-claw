import ClawAgent
import ClawCore
import ClawGateway
import ClawTelegram
import ClawTools
import ClawWorkspace
import Foundation

// MARK: - Agent Stack Assembly

extension DaemonBuilder {
  /// The tool-gated agent stack `makeAgentStack` assembles: the policy-gated dispatcher, the
  /// `AgentRuntime`, and the context builder that folds the static sub-hash into `policy_version`.
  struct AgentStack {
    let toolDispatcher: GatedToolDispatcher
    let agent: AgentRuntime
    let contextBuilder: ContextBuilder
    let presentations: TurnPresentationRegistry
  }

  func makeAgentStack(  // swiftlint:disable:this function_parameter_count
    roster: ProviderRoster,
    cooldown: any PrimaryRouteCooldownTracking,
    workspace: FileSystemWorkspace,
    costResolver: CostResolver,
    sandbox: SandboxStack,
    mcpTools: [any Tool],
    coderTools: [any Tool] = [],
    presentationClock: any Clock<Duration> = ContinuousClock(),
    journal: JournalComposition?
  ) -> AgentStack {
    let toolDispatcher = makeToolDispatcher(
      workspace: workspace,
      sandbox: sandbox,
      mcpTools: mcpTools,
      coderTools: coderTools,
      journal: journal
    )
    let staticSubhash = policyStaticSubhash(toolDispatcher: toolDispatcher, workspace: workspace)
    let draftStreamer = makeDraftStreamer(clock: presentationClock)
    let presentations = TurnPresentationRegistry(
      streamingEnabled: config.llm.streamingEnabled,
      progressEnabled: config.telegramProgressEnabled,
      renderer: TelegramProgressRenderer(actionEmojisEnabled: config.telegramActionEmojisEnabled),
      drafts: draftStreamer,
      typing: TelegramTypingIndicator(transport: transport),
      outbox: stores.outbox,
      draftIDs: stores.draftIDs,
      secretValues: redactionValues,
      clock: presentationClock
    )
    let agent = makeAgent(
      roster: roster,
      cooldown: cooldown,
      toolDispatcher: toolDispatcher,
      costResolver: costResolver,
      draftStreamer: draftStreamer
    )
    let contextBuilder = makeContextBuilder(
      workspace: workspace,
      fenceLabels: ToolFenceLabels(definitions: toolDispatcher.definitions),
      policyStaticSubhash: staticSubhash,
      toolDefinitions: toolDispatcher.definitions,
      journal: journal
    )
    return AgentStack(
      toolDispatcher: toolDispatcher,
      agent: agent,
      contextBuilder: contextBuilder,
      presentations: presentations
    )
  }

  /// Builds the grapheme-budgeted context assembler, injected with the composition root's static
  /// policy sub-hash so `contextBuilder.currentPolicyVersion()` reflects the real tool/config
  /// surface, not a test default.
  func makeContextBuilder(
    workspace: FileSystemWorkspace,
    fenceLabels: ToolFenceLabels,
    policyStaticSubhash: String,
    toolDefinitions: [ToolDefinition],
    journal: JournalComposition?
  ) -> ContextBuilder {
    let messageInputTokens = TokenEstimator.messageInputBudget(
      maxInputTokens: config.budget.maxInputTokens,
      tools: toolDefinitions
    )
    let contextBudget = ContextBudget(
      inputCapGraphemes: TokenEstimator.graphemeBudget(forInputTokens: messageInputTokens),
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
      proactiveSystemPrompt: SystemPrompt.proactive,
      workspace: workspace,
      memoryStore: stores.memory,
      retriever: stores.retriever,
      budget: contextBudget,
      journalFiles: journal?.files,
      journalPolicy: journal?.policy ?? config.journalPolicy,
      fenceLabels: fenceLabels,
      policyStaticSubhash: policyStaticSubhash,
      now: now,
      warn: { warning in
        logger.warning("\(warning)")
      }
    )
  }

  /// Assembles the LLM agent stack: the composed route roster, the shared cooldown ledger, the
  /// injected offline-first cost resolver (shared with the /schedule parse), and the `AgentRuntime`
  /// that orchestrates one turn. Each binding in the roster carries its own erased provider, both
  /// model identities, and both policies, so this seam takes no concrete provider type and whichever
  /// route answers stamps its own billing and reservation. Kept separate from the service wiring so
  /// the composition root reads as "build the agent → feed the turn runner → register the services".
  func makeAgent(
    roster: ProviderRoster,
    cooldown: any PrimaryRouteCooldownTracking,
    toolDispatcher: GatedToolDispatcher,
    costResolver: CostResolver,
    draftStreamer: (any RichDraftStreaming)? = nil
  ) -> AgentRuntime {
    AgentRuntime(
      roster: roster,
      cooldown: cooldown,
      typingIndicator: TelegramTypingIndicator(transport: transport),
      draftStreamer: draftStreamer ?? TelegramRichDraftStreamer(transport: transport),
      streamingEnabled: config.llm.streamingEnabled,
      costResolver: costResolver,
      budget: config.budget,
      toolDispatcher: toolDispatcher,
      usageStore: stores.usage,
      auditLog: stores.audit,
      logger: logger,
      clock: ContinuousClock()
    )
  }
}

// MARK: - Shared Presentation Transport

private extension DaemonBuilder {
  func makeDraftStreamer<C: Clock>(clock: C) -> any RichDraftStreaming
  where C.Duration == Duration {
    TelegramRichDraftStreamer(transport: transport, clock: clock)
  }
}
