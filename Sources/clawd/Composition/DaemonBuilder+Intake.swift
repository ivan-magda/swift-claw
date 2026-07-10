import ClawCore
import ClawGateway
import ClawTools
import ClawWorkspace
import Foundation

// MARK: - Intake Services & Tool Catalog

extension DaemonBuilder {
  /// Wires the inbound/outbound message services: the router that dispatches updates, the poller
  /// that feeds it, and the outbox dispatcher the turn runner pokes via the shared signal.
  func makeIntakeServices(
    coordination: TurnCoordination,
    turnRunner: TurnRunner,
    scheduleSurface: ScheduleSurface,
    approvalCallbacks: ApprovalCallbackHandler
  ) -> (poller: TelegramPollerService, dispatcher: OutboxDispatcher) {
    let router = MessageRouter(
      processed: stores.processed,
      sessionMessages: stores.sessionMessages,
      commands: stores.commands,
      memory: stores.memory,
      memoryCommands: stores.memoryCommands,
      pendingConfirmations: coordination.pendingConfirmations,
      botUsername: botUsername,
      accessControl: AccessControl(allowlist: stores.allowlist),
      delivery: transport,
      turnRunner: turnRunner,
      lanes: coordination.lanes,
      schedule: scheduleSurface,
      approvalCallbacks: approvalCallbacks,
      coordinator: coordination.approvalCoordinator,
      logger: logger
    )
    let poller = TelegramPollerService(
      intake: transport,
      router: router,
      cursor: stores.cursor,
      pollTimeout: config.pollTimeoutSeconds,
      logger: logger
    )
    let dispatcher = OutboxDispatcher(
      outbox: stores.outbox,
      delivery: transport,
      signal: coordination.outboxSignal,
      logger: logger
    )
    return (poller: poller, dispatcher: dispatcher)
  }

  /// Assembles the v1 tool catalog behind its policy gate. Tool fetches use the dedicated
  /// no-redirect `toolExecutor`; no `searchApiKey` ⇒ `web_search` is never constructed
  /// (unconfigured ⇒ absent). Tier-3 private texts load from DISK at gate-evaluation time,
  /// not the assembly snapshot, so the loader closure re-reads the workspace each call.
  func makeToolDispatcher(workspace: FileSystemWorkspace) -> GatedToolDispatcher {
    let secretValues = secrets.redactionValues
    let redactor = SecretRedactor(secretValues: secretValues)

    var tools: [any Tool] = [
      FileReadTool(workspaceRoot: workspace.root, redactor: redactor),
      FileWriteTool(workspaceRoot: workspace.root, redactor: redactor),
      MemoryWriteTool(redactor: redactor),
      WebFetchTool(
        http: toolExecutor,
        resolver: SystemAddressResolver(),
        redactor: redactor,
        exemptCIDRs: config.webFetchExemptCIDRs
      ),
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

  /// Static sub-hash (classes 2–3): the same tool surface the gate enforces, plus the pinned
  /// egress/policy config. Secret values are never hashed — only the base URL, search presence,
  /// and workspace root identity. Injected into `ContextBuilder`, which folds in the class-1 prompt
  /// materials and returns the combined `policy_version`.
  func policyStaticSubhash(
    toolDispatcher: GatedToolDispatcher,
    workspace: FileSystemWorkspace
  ) -> String {
    PolicyFingerprint.staticSubhash(
      tools: toolDispatcher.definitions,
      llmBaseURL: config.llm.baseURL,
      searchEndpointPresent: secrets.searchApiKey != nil,
      workspaceRoot: workspace.root.path
    )
  }
}
