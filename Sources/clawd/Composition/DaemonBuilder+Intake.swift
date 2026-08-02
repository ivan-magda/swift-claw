import ClawAppleSpeech
import ClawCore
import ClawGateway
import ClawTelegram
import ClawTools
import ClawWorkspace
import Foundation

// MARK: - Intake Services & Tool Catalog

extension DaemonBuilder {
  /// The intake services and the image-wired `TurnRunner` the router dispatches through. The runner
  /// is handed back because `MessageRouter` copies it: only the copy the router was built from
  /// carries the cache an inbound photo's bytes land in, so every other consumer that copies a
  /// runner must take THIS one or replay nothing.
  struct IntakeStack {
    let poller: TelegramPollerService
    let outbox: OutboxDispatcher
    let turnRunner: TurnRunner
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

    // The closure parameter deliberately shadows `turnRunner`: inside this body no name resolves to
    // the unwired runner, so the router cannot be built from a copy that predates the image cache.
    let (router, wiredRunner) = ImageWiring.wire(runner: turnRunner) { turnRunner in
      MessageRouter(
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
        voice: voiceService,
        images: imageService,
        typing: TelegramTypingIndicator(transport: transport),
        coordinator: coordination.approvalCoordinator,
        doctor: doctor,
        logger: logger
      )
    }

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
    return IntakeStack(poller: poller, outbox: dispatcher, turnRunner: wiredRunner)
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
      redactor: SecretRedactor(secretValues: secrets.redactionValues),
      logger: logger
    )
  }

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
