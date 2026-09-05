import ClawCore
import ClawGateway
import ClawLLM
import ClawWorkspace
import Foundation

// MARK: - Schedule Surface & Scheduler

extension DaemonBuilder {
  /// Builds the `/schedule` surface: the budget-gated, deadline-bounded draft parser (sharing the
  /// daemon's provider and cost resolver so its ONE LLM call meters spend like a turn), the
  /// deterministic validator, and the read/claim stores. Extracted from `build` so the parser's
  /// spend-discipline wiring reads in one place.
  func makeScheduleSurface(
    roster: ProviderRoster,
    cooldown: any PrimaryRouteCooldownTracking,
    costResolver: CostResolver
  ) -> ScheduleSurface {
    ScheduleSurface(
      parser: ScheduleDraftParser(
        // The same roster and the same cooldown instance `makeAgent` takes: the /schedule parse's
        // one LLM call bills, reserves, and switches routes exactly as a turn does, and a window a
        // turn just armed is one this parse already sees.
        roster: roster,
        cooldown: cooldown,
        usageStore: stores.usage,
        budget: config.budget,
        costResolver: costResolver,
        structuredOutput: config.llm.structuredOutput,
        clock: ContinuousClock(),
        logger: logger
      ),
      validator: ScheduleDraftValidator(
        minIntervalMinutes: config.schedMinIntervalMinutes,
        defaultTimezone: config.timezone
      ),
      calculator: OccurrenceCalculator(),
      jobs: stores.scheduledJobs,
      commands: stores.scheduleCommands
    )
  }

  /// Resolves the heartbeat settings bundle once from config and builds the scheduler around it.
  /// The owner chat id also threads to boot reconcile: a crashed heartbeat run's
  /// synthetic session key carries no chat id, so its crash notice can only reach the owner via
  /// this config-derived target.
  func makeScheduler(
    coordination: TurnCoordination,
    turnRunner: TurnRunner,
    workspace: FileSystemWorkspace,
    learning: ScheduledLearningService?
  ) -> (scheduler: SchedulerService, heartbeatOwner: Int64?) {
    let heartbeatSettings = HeartbeatSettings.resolve(config: config)
    let scheduler = SchedulerService(
      jobs: stores.scheduledJobs,
      lanes: coordination.lanes,
      turns: turnRunner,
      calculator: OccurrenceCalculator(),
      catchUpMaxAge: .seconds(Int64(config.schedCatchUpMaxAgeMinutes) * 60),
      heartbeat: heartbeatSettings,
      workspace: workspace,
      audit: stores.audit,
      learning: learning,
      now: now,
      clock: ContinuousClock(),
      logger: logger
    )
    return (scheduler, config.heartbeatOwnerChatId)
  }
}

// MARK: - Learning Loop

extension DaemonBuilder {
  /// The learning loop's driver, or nil when `CLAW_LEARNING_ENABLED` is unset. Nil is what keeps
  /// the flag-off daemon exactly as it is today: no lane tail settles, no sweep ticks, and no
  /// compatibility or evidence row is written.
  func makeLearningService(
    roster: ProviderRoster,
    cooldown: any PrimaryRouteCooldownTracking,
    costResolver: CostResolver,
    signal: OutboxSignal
  ) -> ScheduledLearningService? {
    guard config.learningEnabled else {
      return nil
    }
    let redactor = SecretRedactor(secretValues: redactionValues)
    let runner = LearningOperationRunner(
      learning: stores.learning,
      jobs: stores.scheduledJobs,
      roster: roster,
      cooldown: cooldown,
      budget: config.budget,
      costResolver: costResolver,
      redactor: redactor,
      logger: logger
    )
    let workflow = LearningWorkflow(
      store: stores.learning,
      jobs: stores.scheduledJobs,
      runner: runner,
      notices: LearningNotices(learning: stores.learning, signal: signal),
      redactor: redactor,
      logger: logger
    )
    return ScheduledLearningService(
      store: stores.learning,
      workflow: workflow,
      now: now,
      logger: logger
    )
  }

  /// The pickup-time compatibility freeze `TurnRunner` calls. Assembled here because the tool
  /// catalog, the skills root and the resolved primary route only exist at the composition root;
  /// the policy version arrives from the caller, so the frozen value is byte-identical to the one
  /// the same pickup stamped on the run.
  func makeLearningSurfaceFreeze(
    toolDefinitions: [ToolDefinition],
    workspace: FileSystemWorkspace
  ) -> @Sendable (_ runId: Int64, _ policyVersion: String) -> Void {
    guard config.learningEnabled else {
      return { _, _ in
      }
    }
    let learning = stores.learning
    let toolCatalogDigest = Self.toolCatalogDigest(toolDefinitions)
    let configuredRoute = config.llm.route.configuredReference
    let logger = logger
    return { runId, policyVersion in
      do {
        // Bound runs only. The skills scan is filesystem work, and an inbound turn — which can
        // never carry a binding — must not pay for a surface that would be discarded anyway.
        guard try learning.binding(runId: runId) != nil else {
          return
        }
        let surface = RunSurface(
          toolCatalogDigest: toolCatalogDigest,
          policyVersion: policyVersion,
          skillSetDigest: Self.skillSetDigest(workspace.scanSkills().descriptors),
          configuredRoute: configuredRoute
        )
        try learning.freezeCompatibility(runId: runId, surface: surface)
      } catch {
        logger.error("run \(runId) compatibility freeze failed: \(error)")
      }
    }
  }

  /// The advertised tool surface, by name and risk tier. Narrower than `policy_version`, which also
  /// folds in prompts and egress config: two runs may share a tool catalog while their prompts
  /// differ, and the evidence window needs to tell those axes apart.
  static func toolCatalogDigest(_ tools: [ToolDefinition]) -> String {
    let parts = tools.sorted { lhs, rhs in
      lhs.name < rhs.name
    }
    .flatMap { tool in
      [tool.name, tool.riskLevel.rawValue]
    }
    return String(PolicyFingerprint.hash(parts: parts).prefix(16))
  }

  /// Name and description of every accepted skill — the index the context actually injects. A skill
  /// body changes what a run can do only once its index row invites the model to load it.
  static func skillSetDigest(_ skills: [SkillDescriptor]) -> String {
    let parts = skills.sorted { lhs, rhs in
      lhs.name < rhs.name
    }
    .flatMap { skill in
      [skill.name, skill.description]
    }
    return String(PolicyFingerprint.hash(parts: parts).prefix(16))
  }
}
