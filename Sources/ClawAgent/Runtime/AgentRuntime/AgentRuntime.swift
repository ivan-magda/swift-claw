import ClawCore
import Foundation
import Logging

/// Runs provider rounds and gated tools under the run's budgets.
///
/// The runtime records intermediate usage and audit events; the gateway owns terminal persistence
/// and delivery. Collaborators are injected through ClawCore protocols.
public struct AgentRuntime: Sendable {
  /// The routes a turn may drive.
  ///
  /// A turn starts on the primary unless it is cooling, and re-resolves its `ActiveRoute` when it
  /// fails over, so accounting and the budget gate follow whichever route really answered rather
  /// than one stamped at init.
  private let roster: ProviderRoster
  /// The primary's cooldown window, armed by a switch and cleared by a healthy answer.
  ///
  /// Absent when nothing composed one — a lone route has nowhere to switch, so it has nothing to
  /// remember.
  let cooldown: (any PrimaryRouteCooldownTracking)?
  let typingIndicator: any TypingIndicator
  let draftStreamer: any RichDraftStreaming
  let streamingEnabled: Bool
  let attemptPolicy: AttemptRuntimePolicy

  // Route-independent: the resolvers and the run budget outlive any one route, so each
  // `ActiveRoute` is derived from them instead of replacing them. `internal`, not `private`, so the
  // extensions in the sibling runtime files reach them alongside the loop.
  let costResolver: CostResolver
  let usageResolver: UsageResolver
  let budget: RunBudget
  let toolDefinitions: [ToolDefinition]

  let toolDispatcher: (any ToolDispatching)?

  let usageStore: any UsageStore
  let auditLog: any AuditLog
  /// Mints the identity each round-trip's usage row is recorded under.
  ///
  /// Injected so a test can pin the identities a run records rather than assert against a random
  /// UUID.
  let providerCallIDGenerator: any ProviderCallIDGenerating
  /// Developer-facing diagnostics (swift-log).
  ///
  /// Distinct from `auditLog`, which is the durable business/security trail. Defaults to a no-op so
  /// tests stay silent unless they inject one.
  let logger: Logger
  /// Injected so tests can script pacing (deadline, backoff) instead of waiting on wall-clock.
  let clock: any Clock<Duration>
  let now: @Sendable () -> ContinuousClock.Instant

  public init(
    roster: ProviderRoster,
    cooldown: (any PrimaryRouteCooldownTracking)? = nil,
    typingIndicator: any TypingIndicator,
    draftStreamer: any RichDraftStreaming,
    streamingEnabled: Bool,
    costResolver: CostResolver,
    usageResolver: UsageResolver = UsageResolver(),
    budget: RunBudget,
    toolDispatcher: (any ToolDispatching)? = nil,
    usageStore: any UsageStore,
    auditLog: any AuditLog,
    providerCallIDGenerator: any ProviderCallIDGenerating = UUIDProviderCallIDGenerator(),
    logger: Logger = Logger(label: "clawd.agent") { _ in
      SwiftLogNoOpLogHandler()
    },
    clock: any Clock<Duration>
  ) {
    self.init(
      roster: roster,
      cooldown: cooldown,
      typingIndicator: typingIndicator,
      draftStreamer: draftStreamer,
      streamingEnabled: streamingEnabled,
      attemptPolicy: .production,
      costResolver: costResolver,
      usageResolver: usageResolver,
      budget: budget,
      toolDispatcher: toolDispatcher,
      usageStore: usageStore,
      auditLog: auditLog,
      providerCallIDGenerator: providerCallIDGenerator,
      logger: logger,
      clock: clock
    ) {
      ContinuousClock.now
    }
  }

  package init(
    roster: ProviderRoster,
    cooldown: (any PrimaryRouteCooldownTracking)? = nil,
    typingIndicator: any TypingIndicator,
    draftStreamer: any RichDraftStreaming,
    streamingEnabled: Bool,
    attemptPolicy: AttemptRuntimePolicy = .production,
    costResolver: CostResolver,
    usageResolver: UsageResolver = UsageResolver(),
    budget: RunBudget,
    toolDispatcher: (any ToolDispatching)? = nil,
    usageStore: any UsageStore,
    auditLog: any AuditLog,
    providerCallIDGenerator: any ProviderCallIDGenerating = UUIDProviderCallIDGenerator(),
    logger: Logger = Logger(label: "clawd.agent") { _ in
      SwiftLogNoOpLogHandler()
    },
    clock: any Clock<Duration>,
    now: @escaping @Sendable () -> ContinuousClock.Instant = {
      ContinuousClock.now
    }
  ) {
    self.roster = roster
    self.cooldown = cooldown
    self.typingIndicator = typingIndicator
    self.draftStreamer = draftStreamer
    self.streamingEnabled = streamingEnabled
    self.attemptPolicy = attemptPolicy

    self.costResolver = costResolver
    self.usageResolver = usageResolver
    self.budget = budget
    self.toolDefinitions = toolDispatcher?.definitions ?? []

    self.toolDispatcher = toolDispatcher

    self.usageStore = usageStore
    self.auditLog = auditLog
    self.providerCallIDGenerator = providerCallIDGenerator

    self.logger = logger

    self.clock = clock
    self.now = now
  }
}

extension AgentRuntime {
  /// Runs the bounded provider and tool loop using an assembled context.
  ///
  /// Each round checks budgets and policy before dispatch and records intermediate usage and audit
  /// events. Failures other than disk-full resolve in the returned outcome.
  ///
  /// - Parameter request: The run segment to execute: whom it serves, its assembled context, the
  ///   session's persisted trust flags, and the spend it starts from.
  /// - Returns: The run-segment result, including approval suspension, plus the tool exchanges,
  ///   accumulated trust flags, and route notice needed by the gateway.
  /// - Throws: `StoreError.diskFull` when a required intermediate write cannot fit on disk.
  public func runTurn(_ request: TurnRequest) async throws -> TurnOutcome {
    let deadline = now() + .seconds(budget.wallClockDeadlineSeconds)
    let route = await TurnRoute(
      roster: roster,
      cooldown: cooldown,
      budget: budget,
      costResolver: costResolver,
      usageResolver: usageResolver
    )
    let turn = TurnFrame(
      scope: request.scope,
      progress: request.progress,
      deadline: deadline,
      startedAt: now(),
      log: turnLogger(for: request.scope)
    )
    turn.log.info(
      """
      turn started model=\(route.active.binding.configuredReference) \
      origin=\(request.scope.origin) \
      contextMessages=\(request.context.messages.count) \
      streaming=\(streamingEnabled) \
      tools=\(toolDefinitions.count)
      """
    )

    var state = TurnState(
      route: route,
      attempts: AttemptRuntimeState(policy: attemptPolicy),
      ledger: RunSpendLedger(
        budget: budget,
        origin: request.scope.origin,
        spend: request.spend
      ),
      trust: TurnTrust(
        session: request.session,
        context: request.context,
        toolDefinitions: toolDefinitions
      ),
      transcript: TurnTranscript(
        wire: request.context.messages,
        toolDefinitions: toolDefinitions
      )
    )
    for index in state.ledger.roundIndices {
      if let exit = try await runRound(index, turn: turn, state: &state) {
        return finish(exit, turn: turn, state: state)
      }
    }

    return finish(
      .budgetStopped(cap: BudgetGate.perRunTurnCap),
      turn: turn,
      state: state
    )
  }
}

// MARK: - Turn Finish

private extension AgentRuntime {
  /// The single terminal choke point for returned outcomes, so each one logs exactly one finished
  /// line. The `StoreError.diskFull` fast path throws to the gateway instead, which logs that
  /// terminal.
  func finish(_ exit: TurnExit, turn: TurnFrame, state: TurnState) -> TurnOutcome {
    Self.logFinish(exit.result, on: turn.log, elapsed: now() - turn.startedAt)
    return state.outcome(for: exit)
  }
}
