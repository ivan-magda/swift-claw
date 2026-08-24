import ClawAppleSpeech
import ClawCore
import ClawGateway
import ClawTelegram
import ClawTools
import ClawWorkspace
import Foundation

// MARK: - Intake Services & Tool Catalog

extension DaemonBuilder {
  struct IntakeStack {
    let poller: TelegramPollerService
    let outbox: OutboxDispatcher
  }

  func makeIntakeServices(
    coordination: TurnCoordination,
    turnRunner: TurnRunner,
    scheduleSurface: ScheduleSurface,
    approvalCallbacks: ApprovalCallbackHandler,
    doctor: any DoctorReporting
  ) -> IntakeStack {
    let voiceService = makeVoiceService()
    let imageService = makeImageService()

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
      imageCache: turnRunner.imageCache,
      lanes: coordination.lanes,
      schedule: scheduleSurface,
      approvalCallbacks: approvalCallbacks,
      voice: voiceService,
      images: imageService,
      typing: TelegramTypingIndicator(transport: transport),
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
    return IntakeStack(poller: poller, outbox: dispatcher)
  }

  /// Nil when the owner opted out, which is what makes the photo path fail closed: the router's only
  /// other branch is the canned "can't read photos yet" reply.
  private func makeImageService() -> ImageMessageService? {
    guard config.image.enabled else {
      return nil
    }
    return ImageMessageService(media: transport, logger: logger)
  }

  private func makeVoiceService() -> VoiceMessageService? {
    VoiceMessageService.sweepStaging(under: config.stateRoot)

    guard config.voice.enabled else {
      return nil
    }

    guard
      let transcriber = SystemVoiceTranscriber.make(
        localeIdentifiers: config.voice.localeIdentifiers,
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
      redactor: SecretRedactor(secretValues: redactionValues),
      logger: logger
    )
  }

  /// The tool catalog the registry advertises: the built-ins, then whatever the pinned MCP catalog
  /// resolved. Remote tools go last so adding a server cannot reorder the built-ins, and the
  /// `mcp__` prefix is what makes a name collision between the two structurally impossible.
  func makeToolDispatcher(
    workspace: FileSystemWorkspace,
    sandbox: SandboxStack,
    mcpTools: [any Tool],
    echo: any ToolInvocationEchoing
  ) -> GatedToolDispatcher {
    let secretValues = redactionValues
    let redactor = SecretRedactor(secretValues: secretValues)

    var tools: [any Tool] = [
      FileReadTool(workspaceRoot: workspace.root, redactor: redactor),
      FileWriteTool(workspaceRoot: workspace.root, redactor: redactor),
      MemoryWriteTool(redactor: redactor),
      SkillLoadTool(
        workspaceRoot: workspace.root,
        scanSkills: { workspace.scanSkills() },
        redactor: redactor
      ),
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

    tools.append(contentsOf: mcpTools)

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
        enabledDangerousTools: enabledDangerousTools
      ),
      echo: echo
    )
  }

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

// MARK: - Dangerous-tier Backstop

private extension DaemonBuilder {
  /// The sandbox and host execution are separate owner decisions, so each dangerous tool carries
  /// its own switch — enabling one must never open the other.
  var enabledDangerousTools: Set<String> {
    var names: Set<String> = []
    if config.exec.enabled {
      names.insert(ExecuteCodeTool.toolName)
    }
    if config.bash.enabled {
      names.insert(BashTool.toolName)
    }
    return names
  }
}
