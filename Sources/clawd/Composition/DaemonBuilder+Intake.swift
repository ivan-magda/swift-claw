import ClawAppleSpeech
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
    approvalCallbacks: ApprovalCallbackHandler,
    doctor: any DoctorReporting
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
      voice: makeVoiceService(),
      coordinator: coordination.approvalCoordinator,
      doctor: doctor,
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

  /// The voice-transcription pipeline, or nil when the flag is off or the host has no on-device
  /// speech engine (Linux, macOS < 26) — the router then falls back to the canned
  /// "can't read voice messages yet" reply, exactly as before the feature existed.
  private func makeVoiceService() -> VoiceMessageService? {
    VoiceMessageService.sweepStaging(under: config.stateRoot)

    guard config.voice.enabled else {
      return nil
    }
    guard
      let transcriber = SystemVoiceTranscriber.make(
        localeIdentifier: config.voice.localeIdentifier,
        maxAudioDurationSeconds: VoiceMessageService.defaultMaxDurationSeconds
      )
    else {
      logger.warning(
        """
        voice transcription is enabled but no on-device speech engine is available; \
        voice messages will get the canned unsupported reply
        """
      )
      return nil
    }

    return VoiceMessageService(
      fetcher: transport,
      transcriber: transcriber,
      stagingDirectory: config.stateRoot.appending(
        path: VoiceMessageService.stagingDirectoryName,
        directoryHint: .isDirectory
      ),
      redactor: SecretRedactor(secretValues: secrets.redactionValues),
      logger: logger
    )
  }

  /// Assembles the v1 tool catalog behind its policy gate. Tool fetches use the dedicated
  /// no-redirect `toolExecutor`; no `searchApiKey` ⇒ `web_search` is never constructed
  /// (unconfigured ⇒ absent). Tier-3 private texts load from DISK at gate-evaluation time,
  /// not the assembly snapshot, so the loader closure re-reads the workspace each call.
  func makeToolDispatcher(
    workspace: FileSystemWorkspace,
    sandbox: SandboxStack
  ) -> GatedToolDispatcher {
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

    if let backend = sandbox.backend, sandbox.health?.isReady == true {
      tools.append(
        ExecuteCodeTool(
          workspaceRoot: workspace.root,
          backend: backend,
          settings: ExecuteCodeSettings(
            memoryMiB: config.exec.memoryMiB,
            cpus: config.exec.cpus,
            timeout: .seconds(config.exec.timeoutSeconds),
            allowEgress: config.exec.allowEgress
          ),
          redactor: redactor
        )
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
        privateFileLoader: privateFileLoader,
        execEnabled: config.exec.enabled
      )
    )
  }

  /// Static sub-hash (classes 2–3): the same tool surface the gate enforces, plus the pinned
  /// egress/policy config: base URL, search presence, workspace identity, web_fetch SSRF
  /// exemptions, and the normalized exec block. Secret values are never hashed. Injected into
  /// `ContextBuilder`, which folds in class-1 prompt materials and returns `policy_version`.
  func policyStaticSubhash(
    toolDispatcher: GatedToolDispatcher,
    workspace: FileSystemWorkspace
  ) -> String {
    PolicyFingerprint.staticSubhash(
      inputs: PolicyFingerprint.StaticInputs(
        tools: toolDispatcher.definitions,
        llmEgress: config.llm.route.descriptor.egress,
        searchEndpointPresent: secrets.searchApiKey != nil,
        workspaceRoot: workspace.root.path,
        webFetchExemptCIDRs: config.webFetchExemptCIDRs,
        exec: config.exec
      )
    )
  }
}
