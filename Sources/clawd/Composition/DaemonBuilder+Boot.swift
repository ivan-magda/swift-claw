import ClawCore
import ClawGateway
import Foundation

// MARK: - Boot Sequence

extension DaemonBuilder {
  static let botMenuCommands = [
    BotMenuCommand(command: "start", description: "Start the bot."),
    BotMenuCommand(command: "new", description: "Start a new session."),
    BotMenuCommand(command: "stop", description: "Stop the current run."),
    BotMenuCommand(command: "remember", description: "Save a memory."),
    BotMenuCommand(command: "memory", description: "Review saved memories."),
    BotMenuCommand(command: "schedule", description: "Create or list schedules."),
    BotMenuCommand(command: "learning", description: "Inspect scheduled-job learning."),
    BotMenuCommand(command: "pause", description: "Pause a schedule."),
    BotMenuCommand(command: "resume", description: "Resume a paused schedule."),
    BotMenuCommand(command: "runnow", description: "Run a schedule now."),
    BotMenuCommand(command: "cancel", description: "Cancel a schedule."),
    BotMenuCommand(command: "status", description: "Show daemon health."),
    BotMenuCommand(command: "mcp", description: "Show MCP server status."),
    BotMenuCommand(command: "skills", description: "Show accepted and rejected skills."),
    BotMenuCommand(command: "help", description: "Show commands and confirm rules."),
  ]

  /// Composes the daemon's one-shot boot reconciliation: register the command menu with Telegram
  /// (`registerMenu`), sweep crash-orphaned runs (`reconcileRuns`), then re-park unresolved
  /// approvals (`reconcileApprovals`). Each step is best-effort, but `reconcileApprovals` is
  /// deliberately last: the run sweep must fail its orphans first so the approval sweep only sees
  /// runs that are genuinely still parked. All three run before any update is served.
  func bootSequence(
    coordination: TurnCoordination,
    waiter: ApprovalWaiter,
    heartbeatOwner: Int64?,
    learning: ScheduledLearningService?
  ) -> @Sendable () async -> Void {
    let registerMenu = registerMenuCommands()
    let reconcileRuns = bootReconcile(heartbeatOwner: heartbeatOwner)
    let reconcileApprovals = bootReconcileApprovals(
      coordination: coordination,
      waiter: waiter,
      learning: learning
    )
    return {
      await registerMenu()
      await reconcileRuns()
      await reconcileApprovals()
      // Last, and read-only with respect to settlement: it seals what the run sweep just froze
      // without settling anything itself, so the ordering the run sweep and the approval backstop
      // depend on is untouched.
      await learning?.reconcileAtBoot(now: now())
    }
  }

  /// Builds the boot step that registers the command menu with Telegram. This is a reconciliation:
  /// `setMyCommands` writes persistent server-side state, so re-declaring on every boot keeps the
  /// registered picker in sync with this build's `botMenuCommands`. Best-effort — a failure only
  /// means the picker is stale, never that the bot can't serve.
  func registerMenuCommands() -> @Sendable () async -> Void {
    {
      do {
        try await transport.setMyCommands(Self.botMenuCommands)
      } catch {
        logger.warning("setMyCommands failed: \(error)")
      }
    }
  }

  /// The boot step that sweeps any run left RUNNING by a crash to FAILED and enqueues a degradation
  /// reply, so a turn interrupted mid-flight is never silent. It runs before the services
  /// serve, so the dispatcher's boot drain delivers whatever this enqueues.
  func bootReconcile(heartbeatOwner: Int64?) -> @Sendable () async -> Void {
    {
      do {
        let replies = try stores.runs.reconcileRunsAtBoot(
          now: now(),
          degradationText: Degradation.unfinished,
          heartbeatNoticeChatId: heartbeatOwner
        )
        if !replies.isEmpty {
          logger.warning(
            "boot reconcile: \(replies.count) unfinished run(s) → degradation enqueued"
          )
        }
      } catch {
        logger.error("boot reconcile failed: \(error)")
      }
    }
  }

  /// The boot step that re-establishes the approval fabric after a restart: terminal-run
  /// PENDING rows are cleaned, unexpired parked approvals are re-parked on their lanes so buttons
  /// and the FIFO queue-behind contract survive restart, expired ones are swept to DENY→FAILED,
  /// and an APPROVED row left by a crash between grant and execution is resumed under the
  /// re-validation belt. Runs before the services serve, so the re-parked lanes are live before
  /// the first callback arrives.
  func bootReconcileApprovals(
    coordination: TurnCoordination,
    waiter: ApprovalWaiter,
    learning: ScheduledLearningService?
  ) -> @Sendable () async -> Void {
    let reconciler = ApprovalBootReconciler(
      approvals: stores.approvals,
      runs: stores.runs,
      lanes: coordination.lanes,
      coordinator: coordination.approvalCoordinator,
      waiter: waiter,
      learning: learning,
      now: { Date() },
      logger: logger
    )
    return {
      await reconciler.reconcile()
    }
  }
}
