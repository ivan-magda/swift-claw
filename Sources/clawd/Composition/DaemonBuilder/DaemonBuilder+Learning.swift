import ClawCore
import ClawGateway
import ClawLLM
import ClawWorkspace
import Foundation

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

  /// The store the turn path reads a bound run's pinned lessons through, or nil when
  /// `CLAW_LEARNING_ENABLED` is unset. Gated here, not left to the fire path having written no
  /// binding: a run bound while the flag was on can be parked on an approval, survive a restart
  /// that removed the flag, and resume — boot reconciliation deliberately leaves AWAITING_APPROVAL
  /// runs alone. A disarmed daemon therefore has to refuse the read itself.
  func makePinnedLessonStore() -> (any ScheduledLearningStore)? {
    guard config.learningEnabled else {
      return nil
    }
    return stores.learning
  }

  /// Feedback is inert while learning is disarmed: no target is created and no old target may
  /// mutate learning state after the operator removes the feature flag.
  func makeFeedbackCallbackHandler(
    challenges: FeedbackChallengeHandler?,
    learning: ScheduledLearningService?
  ) -> FeedbackCallbackHandler? {
    guard config.learningEnabled else {
      return nil
    }
    return FeedbackCallbackHandler.make(
      processed: stores.processed,
      delivery: transport,
      accessControl: AccessControl(allowlist: stores.allowlist, groupChats: []),
      learning: stores.learning,
      audit: stores.audit,
      callbacks: transport,
      challenges: challenges,
      workflow: learning,
      now: now,
      logger: logger
    )
  }

  /// The same feature gate controls both halves of free-text feedback: opening from a callback and
  /// intercepting the next direct owner message.
  func makeFeedbackChallengeHandler(
    coordination: TurnCoordination,
    learning: ScheduledLearningService?
  ) -> FeedbackChallengeHandler? {
    guard config.learningEnabled else {
      return nil
    }
    let signal = coordination.outboxSignal
    return FeedbackChallengeHandler.make(
      processed: stores.processed,
      delivery: transport,
      learning: stores.learning,
      workflow: learning,
      notifyOutbox: { signal.poke() },
      now: now,
      logger: logger
    )
  }
}
