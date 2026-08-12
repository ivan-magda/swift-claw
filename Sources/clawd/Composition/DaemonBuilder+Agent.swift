import ClawAgent
import ClawCore
import ClawGateway
import ClawLLM
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
  }

  func makeAgentStack(
    roster: ProviderRoster,
    cooldown: any PrimaryRouteCooldownTracking,
    workspace: FileSystemWorkspace,
    costResolver: CostResolver,
    sandbox: SandboxStack,
    mcpTools: [any Tool]
  ) -> AgentStack {
    let toolDispatcher = makeToolDispatcher(
      workspace: workspace,
      sandbox: sandbox,
      mcpTools: mcpTools
    )
    let staticSubhash = policyStaticSubhash(toolDispatcher: toolDispatcher, workspace: workspace)
    let agent = makeAgent(
      roster: roster,
      cooldown: cooldown,
      toolDispatcher: toolDispatcher,
      costResolver: costResolver
    )
    let contextBuilder = makeContextBuilder(
      workspace: workspace,
      fenceLabels: ToolFenceLabels(definitions: toolDispatcher.definitions),
      policyStaticSubhash: staticSubhash,
      toolDefinitions: toolDispatcher.definitions
    )
    return AgentStack(toolDispatcher: toolDispatcher, agent: agent, contextBuilder: contextBuilder)
  }

  /// Builds the grapheme-budgeted context assembler, injected with the composition root's static
  /// policy sub-hash so `contextBuilder.currentPolicyVersion()` reflects the real tool/config
  /// surface, not a test default.
  func makeContextBuilder(
    workspace: FileSystemWorkspace,
    fenceLabels: ToolFenceLabels,
    policyStaticSubhash: String,
    toolDefinitions: [ToolDefinition]
  ) -> ContextBuilder {
    let messageInputTokens = TokenEstimator.messageInputBudget(
      maxInputTokens: config.budget.maxInputTokens,
      tools: toolDefinitions
    )
    let contextBudget = ContextBudget(
      inputCapGraphemes: TokenEstimator.graphemeBudget(
        forInputTokens: messageInputTokens
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
      proactiveSystemPrompt: SystemPrompt.proactive,
      workspace: workspace,
      memoryStore: stores.memory,
      retriever: stores.retriever,
      budget: contextBudget,
      fenceLabels: fenceLabels,
      policyStaticSubhash: policyStaticSubhash,
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
    costResolver: CostResolver
  ) -> AgentRuntime {
    AgentRuntime(
      roster: roster,
      cooldown: cooldown,
      typingIndicator: TelegramTypingIndicator(transport: transport),
      draftStreamer: TelegramRichDraftStreamer(transport: transport),
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
