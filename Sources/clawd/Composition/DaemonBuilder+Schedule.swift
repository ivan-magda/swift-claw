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
    provider: OpenAICompatibleProvider,
    costResolver: CostResolver
  ) -> ScheduleSurface {
    ScheduleSurface(
      parser: ScheduleDraftParser(
        provider: provider,
        // The wired provider is the metered OpenAI-compatible route, so the wire model and the
        // accounting identity are the same configured string and the policies stay at their
        // metered/text-only defaults — the same injection `makeAgent` gives the turn runtime, so a
        // subscription route would swap both here and there together.
        wireModel: config.llm.model,
        configuredReference: config.llm.model,
        usageStore: stores.usage,
        budget: config.budget,
        costResolver: costResolver,
        costPolicy: .metered,
        reservationPolicy: .textOnly,
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
    workspace: FileSystemWorkspace
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
      now: { Date() },
      clock: ContinuousClock(),
      logger: logger
    )
    return (scheduler, heartbeatSettings.ownerChatId)
  }
}
