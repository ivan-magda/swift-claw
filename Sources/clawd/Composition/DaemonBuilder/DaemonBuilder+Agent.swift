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
  struct AgentStack {
    let toolDispatcher: GatedToolDispatcher
    let agent: AgentRuntime
    let contextBuilder: ContextBuilder
  }

  func makeAgentStack(  // swiftlint:disable:this function_parameter_count
    roster: ProviderRoster,
    cooldown: any PrimaryRouteCooldownTracking,
    workspace: FileSystemWorkspace,
    costResolver: CostResolver,
    sandbox: SandboxStack,
    mcpTools: [any Tool],
    coderTools: [any Tool] = [],
    conferenceProfile: Bool = false,
    conferenceTools: [any Tool] = []
  ) -> AgentStack {
    let toolDispatcher = makeToolDispatcher(
      workspace: workspace,
      sandbox: sandbox,
      mcpTools: mcpTools,
      coderTools: coderTools,
      conferenceProfile: conferenceProfile,
      conferenceTools: conferenceTools
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
