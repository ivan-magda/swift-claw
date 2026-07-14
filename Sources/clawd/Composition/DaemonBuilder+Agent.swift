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

  func makeProvider() -> OpenAICompatibleProvider {
    OpenAICompatibleProvider(
      config: config.llm.withAPIKey(secrets.llmApiKey ?? ""),
      http: executor,
      clock: ContinuousClock(),
      jitter: { cap in
        Duration.seconds(Double.random(in: 0...(cap / .seconds(1))))
      },
      logger: logger
    )
  }

  func makeAgentStack(
    provider: OpenAICompatibleProvider,
    workspace: FileSystemWorkspace,
    costResolver: CostResolver,
    sandbox: SandboxStack
  ) -> AgentStack {
    let toolDispatcher = makeToolDispatcher(workspace: workspace, sandbox: sandbox)
    let staticSubhash = policyStaticSubhash(toolDispatcher: toolDispatcher, workspace: workspace)
    let agent = makeAgent(
      provider: provider,
      toolDispatcher: toolDispatcher,
      costResolver: costResolver
    )
    let contextBuilder = makeContextBuilder(
      workspace: workspace,
      policyStaticSubhash: staticSubhash
    )
    return AgentStack(toolDispatcher: toolDispatcher, agent: agent, contextBuilder: contextBuilder)
  }

  /// Builds the grapheme-budgeted context assembler, injected with the composition root's static
  /// policy sub-hash so `contextBuilder.currentPolicyVersion()` reflects the real tool/config
  /// surface, not a test default.
  func makeContextBuilder(
    workspace: FileSystemWorkspace,
    policyStaticSubhash: String
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
      proactiveSystemPrompt: SystemPrompt.proactive,
      workspace: workspace,
      memoryStore: stores.memory,
      retriever: stores.retriever,
      budget: contextBudget,
      policyStaticSubhash: policyStaticSubhash,
      warn: { warning in
        logger.warning("\(warning)")
      }
    )
  }

  /// Assembles the LLM agent stack: the OpenAI-compatible provider, the injected offline-first cost
  /// resolver (shared with the /schedule parse), and the `AgentRuntime` that orchestrates one turn.
  /// Kept separate from the service wiring so the composition root reads as "build the agent → feed
  /// the turn runner → register the services".
  func makeAgent(
    provider: OpenAICompatibleProvider,
    toolDispatcher: GatedToolDispatcher,
    costResolver: CostResolver
  ) -> AgentRuntime {
    AgentRuntime(
      provider: provider,
      typingIndicator: TelegramTypingIndicator(transport: transport),
      draftStreamer: TelegramRichDraftStreamer(transport: transport),
      streamingEnabled: config.llm.streamingEnabled,
      costResolver: costResolver,
      budget: config.budget,
      model: config.llm.model,
      toolDispatcher: toolDispatcher,
      usageStore: stores.usage,
      auditLog: stores.audit,
      logger: logger,
      clock: ContinuousClock()
    )
  }
}
