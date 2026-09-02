import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawMCP
import ClawSecrets
import ClawTelegram
import ClawWorkspace
import Foundation
import Logging
import ServiceLifecycle
import UnixSignals

/// The composition root. Holds the cross-cutting inputs `run()` resolves before wiring — config,
/// secrets, stores, the dedicated tool executor, the Telegram transport, and the logger — plus the
/// lazy managed-store factory. `makeRosterStack` resolves the configured routes into erased
/// providers on the dedicated LLM executor, and `build(rosterStack:cooldown:)` assembles the whole
/// service graph from them: the roster + agent feed a `TurnRunner`, which the router dispatches from
/// the poller. The `make*` builders are organized by subsystem in `DaemonBuilder+*.swift`.
struct DaemonBuilder: Sendable {
  let config: AppConfig
  let secrets: Secrets
  let stores: ClawStores

  let toolExecutor: any HTTPExecuting & HTTPStreaming

  let transport: TelegramClient
  let botIdentity: BotIdentity?

  let mcp: MCPBootInputs

  let logger: Logger

  /// Builds the encrypted credential store the managed route loads its record from. A field rather
  /// than a literal so a composition test scripts a missing or malformed envelope in place of the
  /// real one; the current route never invokes it.
  let makeManagedStore: @Sendable () -> any LLMCredentialStore

  /// The one redaction set for this process — secret-store values plus MCP tokens. Every redactor
  /// and arg guard the builder makes reads this instead of `secrets.redactionValues`, so none of
  /// them can be built from a narrower list than the log backend was. Derived rather than passed in:
  /// a caller that could supply the list is a caller that could supply a shorter one.
  var redactionValues: [String] { mcp.redactionValues(with: secrets) }

  /// The single production bound on both the ServiceGroup's graceful window and the lane drain, so
  /// admission-close, cancel, and the bounded drain all share one deadline.
  static let gracefulShutdownSeconds = 30

  /// Resolves every configured route into a provider roster on the dedicated LLM executor. It
  /// supplies only inputs — the resolved routes and settings, the two lazy bearers, the lazy managed
  /// store, the executor, and the build version — while the tested `ProviderStackFactory` in
  /// `ClawLLM` owns the selection. Each bearer is read only for the route it belongs to and the
  /// managed store is built only for the ChatGPT route, so a route never opens another's credential
  /// path. A fallback that cannot be built throws here, at boot, rather than at the 3am the
  /// primary's quota runs out; a malformed or insecure managed envelope throws the closed store
  /// taxonomy for the caller to map.
  func makeRosterStack(http: any HTTPExecuting & HTTPStreaming) throws -> RosterStack {
    try ProviderStackFactory.makeRoster(
      primaryRoute: config.llm.route,
      fallbackRoute: config.llm.fallbackRoute,
      settings: config.llm,
      loadStaticBearer: { secrets.llmApiKey },
      loadFallbackBearer: { secrets.llmFallbackApiKey },
      makeManagedCredentialStore: makeManagedStore,
      http: http,
      buildVersion: ClawdVersion.current
    )
  }

  /// - Parameter cooldown: the ONE window ledger the turn path and the `/schedule` parse share, so a
  ///   route a turn just walled off is not re-probed by the very next scheduled parse.
  func build(
    rosterStack: RosterStack,
    cooldown: any PrimaryRouteCooldownTracking
  ) async throws -> DaemonRuntimeBundle {
    let sandbox = await prepareSandbox()
    let coordination = TurnCoordination()

    // Hoisted so the agent and the /schedule parse share one offline-first cost resolver — both
    // meter spend against the same price snapshot and reference rate.
    let costResolver = CostResolver(
      priceTable: PriceFileLoader.load(),
      referenceUSDPerToken: config.budget.referenceUSDPerToken
    )

    // Pinned here, before the agent stack: the remote catalog is part of the tool surface the
    // registry advertises and `policy_version` folds over, so it has to be settled before either
    // exists. Nothing in it can fail the boot.
    let mcpStack = await resolveMCPStack()

    let workspace = FileSystemWorkspace(root: EnvironmentLoader.workspaceRoot(config: config))
    let roster = rosterStack.roster
    let agentStack = makeAgentStack(
      roster: roster,
      cooldown: cooldown,
      workspace: workspace,
      costResolver: costResolver,
      sandbox: sandbox,
      mcpTools: mcpStack.tools
    )

    let learning = makeLearningService()
    let consumers = makeRunnerConsumers(
      coordination: coordination,
      agentStack: agentStack,
      roster: roster,
      cooldown: cooldown,
      costResolver: costResolver,
      workspace: workspace,
      sandbox: sandbox,
      mcpCatalog: mcpStack.catalog,
      learning: learning
    )

    var services: [any Service] = [
      consumers.poller,
      consumers.outbox,
      consumers.scheduler,
      consumers.approvals.expiry,
    ]
    if let learning {
      services.append(learning)
    }
    if let maintenance = sandbox.maintenance {
      services.append(SandboxLifecycleService(maintenance: maintenance))
    }
    if mcpStack.sessions.isEmpty == false {
      services.append(MCPSessionLifecycleService(sessions: mcpStack.sessions))
    }

    return runtimeBundle(
      services: services,
      coordination: coordination,
      // The shutdown bundle commits the rotation of every source the roster authorized with —
      // primary first, in route order — hoisted here from the stack the factory composed.
      credentialSources: rosterStack.credentialSources,
      boot: bootSequence(
        coordination: coordination,
        waiter: consumers.approvals.waiter,
        heartbeatOwner: consumers.heartbeatOwner,
        learning: learning
      )
    )
  }

  /// Every service that copies the `TurnRunner` value — the router inside the poller, the approval
  /// waiter, and the scheduler.
  struct RunnerConsumers {
    let poller: TelegramPollerService
    let outbox: OutboxDispatcher<ContinuousClock>
    let approvals: ApprovalFabric
    let scheduler: SchedulerService
    let heartbeatOwner: Int64?
  }

  /// Assembles those consumers together rather than at four call sites so they share one runner
  /// value and, with it, the one image cache an inbound photo's bytes land in.
  func makeRunnerConsumers(  // swiftlint:disable:this function_parameter_count
    coordination: TurnCoordination,
    agentStack: AgentStack,
    roster: ProviderRoster,
    cooldown: any PrimaryRouteCooldownTracking,
    costResolver: CostResolver,
    workspace: FileSystemWorkspace,
    sandbox: SandboxStack,
    mcpCatalog: ResolvedMCPCatalog,
    learning: ScheduledLearningService?
  ) -> RunnerConsumers {
    let turnRunner = makeTurnRunner(
      coordination: coordination,
      agentStack: agentStack,
      costPolicy: roster.primary.costPolicy,
      imageCache: ImageCache(),
      freezeLearningSurface: makeLearningSurfaceFreeze(
        agentStack: agentStack,
        workspace: workspace
      )
    )
    let intake = makeIntakeServices(
      coordination: coordination,
      turnRunner: turnRunner,
      scheduleSurface: makeScheduleSurface(
        roster: roster,
        cooldown: cooldown,
        costResolver: costResolver
      ),
      approvalCallbacks: makeApprovalCallbackHandler(
        coordination: coordination,
        agentStack: agentStack
      ),
      doctor: makeDoctorReporter(
        sandbox: sandbox,
        cooldown: cooldown,
        mcpOutcomes: mcpCatalog.outcomes
      ),
      learning: learning
    )
    let approvals = makeApprovalFabric(
      coordination: coordination,
      agentStack: agentStack,
      turnRunner: turnRunner
    )
    let (scheduler, heartbeatOwner) = makeScheduler(
      coordination: coordination,
      turnRunner: turnRunner,
      workspace: workspace,
      learning: learning
    )

    return RunnerConsumers(
      poller: intake.poller,
      outbox: intake.outbox,
      approvals: approvals,
      scheduler: scheduler,
      heartbeatOwner: heartbeatOwner
    )
  }

  /// Wraps the assembled service graph with the lane-shutdown lifecycle: mints the drain-outcome
  /// owner, registers the lane-admission service last, and returns the bundle carrying the exact lane
  /// registry and credential source the shutdown sequence must own.
  func runtimeBundle(
    services: [any Service],
    coordination: TurnCoordination,
    credentialSources: [any LLMCredentialSource],
    boot: @escaping @Sendable () async -> Void,
    laneDrainClock: any Clock<Duration> = ContinuousClock(),
    gracefulShutdownSignals: [UnixSignal] = [.sigterm, .sigint]
  ) -> DaemonRuntimeBundle {
    let laneShutdownOutcome = LaneShutdownOutcome()
    let laneAdmission = LaneAdmissionShutdownService(
      lanes: coordination.lanes,
      outcome: laneShutdownOutcome,
      drainTimeout: .seconds(Self.gracefulShutdownSeconds),
      clock: laneDrainClock,
      logger: logger
    )

    let daemon = Daemon(
      services: Self.servicesWithLaneAdmissionLast(base: services, laneAdmission: laneAdmission),
      boot: boot,
      logger: logger,
      gracefulShutdownSignals: gracefulShutdownSignals,
      gracefulShutdownSeconds: Self.gracefulShutdownSeconds
    )

    return DaemonRuntimeBundle(
      daemon: daemon,
      lanes: coordination.lanes,
      credentialSources: credentialSources,
      laneShutdownOutcome: laneShutdownOutcome
    )
  }

  /// Appends the lane-admission service LAST. ServiceLifecycle shuts services down in reverse array
  /// order, so the last-registered service is the first to receive graceful shutdown — the lanes
  /// must close admission and drain before any service they depend on tears down.
  static func servicesWithLaneAdmissionLast(
    base: [any Service],
    laneAdmission: LaneAdmissionShutdownService
  ) -> [any Service] {
    base + [laneAdmission]
  }
}
