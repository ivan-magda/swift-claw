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
      toolDefinitions: toolDispatcher.definitions,
      systemPrompt: conferenceProfile ? SystemPrompt.conference : SystemPrompt.minimal,
      conferenceProfile: conferenceProfile
    )
    return AgentStack(toolDispatcher: toolDispatcher, agent: agent, contextBuilder: contextBuilder)
  }

  func makeContextBuilder(
    workspace: FileSystemWorkspace,
    fenceLabels: ToolFenceLabels,
    policyStaticSubhash: String,
    toolDefinitions: [ToolDefinition],
    systemPrompt: String = SystemPrompt.minimal,
    conferenceProfile: Bool = false
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
    // Conference topics share only their transcript, without personal workspace or recall data.
    let contextWorkspace: any WorkspaceReading
    let contextMemory: any MemoryStore
    let contextRetriever: any Retriever
    if conferenceProfile {
      contextWorkspace = ClawAgent.EmptyWorkspace()
      contextMemory = ClawAgent.EmptyMemoryStore()
      contextRetriever = ClawAgent.EmptyRetriever()
    } else {
      contextWorkspace = workspace
      contextMemory = stores.memory
      contextRetriever = stores.retriever
    }
    return ContextBuilder(
      systemPrompt: systemPrompt,
      proactiveSystemPrompt: SystemPrompt.proactive,
      workspace: contextWorkspace,
      memoryStore: contextMemory,
      retriever: contextRetriever,
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
