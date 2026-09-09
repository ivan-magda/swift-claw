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
    let outbox: OutboxDispatcher<ContinuousClock>
  }

  func makeIntakeServices(
    coordination: TurnCoordination,
    turnRunner: TurnRunner,
    scheduleSurface: ScheduleSurface,
    approvalCallbacks: ApprovalCallbackHandler,
    doctor: any DoctorReporting,
    learning: ScheduledLearningService?,
    conferenceProfile: Bool = false
  ) -> IntakeStack {
    let router = makeIntakeRouter(
      coordination: coordination,
      turnRunner: turnRunner,
      imageCache: turnRunner.imageCache,
      scheduleSurface: scheduleSurface,
      approvalCallbacks: approvalCallbacks,
      doctor: doctor,
      learning: learning,
      conferenceProfile: conferenceProfile
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

  func makeIntakeRouter(  // swiftlint:disable:this function_parameter_count
    coordination: TurnCoordination,
    turnRunner: any TurnDispatching,
    imageCache: ImageCache,
    scheduleSurface: ScheduleSurface,
    approvalCallbacks: ApprovalCallbackHandler?,
    doctor: any DoctorReporting,
    learning: ScheduledLearningService?,
    conferenceProfile: Bool = false
  ) -> MessageRouter {
    let voiceService = conferenceProfile ? nil : makeVoiceService()
    let imageService = conferenceProfile ? nil : makeImageService()
    let feedbackChallenges = conferenceProfile
      ? nil
      : makeFeedbackChallengeHandler(coordination: coordination, learning: learning)

    return MessageRouter(
      processed: stores.processed,
      sessionMessages: stores.sessionMessages,
      commands: stores.commands,
      memory: stores.memory,
      memoryCommands: stores.memoryCommands,
      pendingConfirmations: coordination.pendingConfirmations,
      botIdentity: botIdentity,
      accessControl: AccessControl(
        allowlist: stores.allowlist,
        groupChats: config.groupChats,
        allowUnlistedPrivateUsers: conferenceProfile
      ),
      delivery: transport,
      turnRunner: turnRunner,
      imageCache: imageCache,
      lanes: coordination.lanes,
      schedule: scheduleSurface,
      learning: conferenceProfile ? nil : learning,
      learningStore: conferenceProfile ? nil : stores.learning,
      learningRedactor: conferenceProfile ? nil : SecretRedactor(secretValues: redactionValues),
      learningOutboxSignal: conferenceProfile ? nil : coordination.outboxSignal,
      approvalCallbacks: approvalCallbacks,
      feedbackCallbacks: conferenceProfile
        ? nil
        : makeFeedbackCallbackHandler(challenges: feedbackChallenges, learning: learning),
      feedbackChallenges: feedbackChallenges,
      voice: voiceService,
      images: imageService,
      typing: TelegramTypingIndicator(transport: transport),
      conferenceProfile: conferenceProfile,
      coordinator: coordination.approvalCoordinator,
      doctor: doctor,
      now: now,
      logger: logger
    )
  }

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

  /// In the conference profile this is an allowlist, not an additive catalog: only the three
  /// conference tools exist. That property is what makes admitting previously-unlisted private
  /// participants safe on the dedicated state root.
  func makeToolDispatcher(
    workspace: FileSystemWorkspace,
    sandbox: SandboxStack,
    mcpTools: [any Tool],
    coderTools: [any Tool] = [],
    conferenceProfile: Bool = false,
    conferenceTools: [any Tool] = []
  ) -> GatedToolDispatcher {
    let secretValues = redactionValues
    let redactor = SecretRedactor(secretValues: secretValues)

    let tools: [any Tool]
    let enabledDangerousTools: Set<String>
    if conferenceProfile {
      tools = conferenceTools
      enabledDangerousTools = Set(
        conferenceTools.filter { $0.definition.riskLevel == .dangerous }.map(\.definition.name)
      )
    } else {
      var ordinary: [any Tool] = [
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
        ordinary.append(
          WebSearchTool(search: ExaSearchProvider(apiKey: searchApiKey, http: toolExecutor))
        )
      }

      if let backend = sandbox.backend, sandbox.health?.isReady == true {
        ordinary.append(
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

      ordinary.append(contentsOf: coderTools)
      ordinary.append(contentsOf: mcpTools)
      tools = ordinary
      enabledDangerousTools = Set(
        (config.exec.enabled ? [ExecuteCodeTool.name] : [])
          + coderTools.map(\.definition.name)
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
        enabledDangerousTools: enabledDangerousTools
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
