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

struct DaemonBuilder: Sendable {
  let config: AppConfig
  let secrets: Secrets
  let stores: ClawStores

  let toolExecutor: any HTTPExecuting & HTTPStreaming
  let transport: TelegramClient
  let botIdentity: BotIdentity?
  let mcp: MCPBootInputs
  let logger: Logger
  var now: @Sendable () -> Date = { Date() }

  let makeManagedStore: @Sendable () -> any LLMCredentialStore

  var resolveCoder: @Sendable (CoderConfig) async throws -> CoderBackendSetup = CoderBackendSetup
    .live

  var redactionValues: [String] { mcp.redactionValues(with: secrets) }

  static let gracefulShutdownSeconds = 30

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

  func build(
    rosterStack: RosterStack,
    cooldown: any PrimaryRouteCooldownTracking
  ) async throws -> DaemonRuntimeBundle {
    let conferenceConfig = try loadConferenceConfig()
    let sandbox: SandboxStack
    if conferenceConfig.enabled {
      sandbox = SandboxBootstrapResult(
        backend: nil,
        maintenance: nil,
        health: nil,
        unavailableReason: "code execution is disabled in conference mode"
      )
    } else {
      sandbox = await prepareSandbox()
    }

    let coordination = TurnCoordination()
    let coder = await prepareCoder(coordination: coordination)
    let conference = try prepareConference(
      config: conferenceConfig,
      coder: coder,
      coordination: coordination
    )

    let costResolver = CostResolver(
      priceTable: PriceFileLoader.load(),
      referenceUSDPerToken: config.budget.referenceUSDPerToken
    )

    let mcpStack = conference.enabled ? MCPStack.empty : await resolveMCPStack()

    let workspace = FileSystemWorkspace(root: EnvironmentLoader.workspaceRoot(config: config))
    let roster = rosterStack.roster
    let agentStack = makeAgentStack(
      roster: roster,
      cooldown: cooldown,
      workspace: workspace,
      costResolver: costResolver,
      sandbox: sandbox,
      mcpTools: mcpStack.tools,
      coderTools: coder.tools,
      conferenceProfile: conference.enabled,
      conferenceTools: conference.tools
    )

    let learning: ScheduledLearningService?
    if conference.enabled {
      learning = nil
    } else {
      learning = makeLearningService(
        roster: roster,
        cooldown: cooldown,
        costResolver: costResolver,
        signal: coordination.outboxSignal
      )
    }
    let consumers = makeRunnerConsumers(
      coordination: coordination,
      agentStack: agentStack,
      roster: roster,
      cooldown: cooldown,
      costResolver: costResolver,
      workspace: workspace,
      sandbox: sandbox,
      mcpCatalog: mcpStack.catalog,
      coder: coder,
      learning: learning,
      conferenceProfile: conference.enabled
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

    let postCoderServices: [any Service] = conference.service.map { [$0 as any Service] } ?? []
    return runtimeBundle(
      services: services,
      coordination: coordination,
      credentialSources: rosterStack.credentialSources,
      boot: bootSequence(
        coordination: coordination,
        waiter: consumers.approvals.waiter,
        heartbeatOwner: consumers.heartbeatOwner,
        coder: coder.service,
        learning: learning
      ),
      coder: coder.service,
      afterCoderServices: postCoderServices
    )
  }

  struct RunnerConsumers {
    let poller: TelegramPollerService
    let outbox: OutboxDispatcher<ContinuousClock>
    let approvals: ApprovalFabric
    let scheduler: SchedulerService
    let heartbeatOwner: Int64?
  }

  func makeRunnerConsumers(  // swiftlint:disable:this function_parameter_count
    coordination: TurnCoordination,
    agentStack: AgentStack,
    roster: ProviderRoster,
    cooldown: any PrimaryRouteCooldownTracking,
    costResolver: CostResolver,
    workspace: FileSystemWorkspace,
    sandbox: SandboxStack,
    mcpCatalog: ResolvedMCPCatalog,
    coder: CoderComposition,
    learning: ScheduledLearningService?,
    conferenceProfile: Bool = false
  ) -> RunnerConsumers {
    let turnRunner = makeTurnRunner(
      coordination: coordination,
      agentStack: agentStack,
      costPolicy: roster.primary.costPolicy,
      imageCache: ImageCache(),
      freezeLearningSurface: makeLearningSurfaceFreeze(
        toolDefinitions: agentStack.toolDispatcher.definitions,
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
        agentStack: agentStack,
        conferenceProfile: conferenceProfile
      ),
      doctor: makeDoctorReporter(
        sandbox: sandbox,
        cooldown: cooldown,
        mcpOutcomes: mcpCatalog.outcomes,
        coder: coder
      ),
      learning: learning,
      conferenceProfile: conferenceProfile
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

  func runtimeBundle(
    services: [any Service],
    coordination: TurnCoordination,
    credentialSources: [any LLMCredentialSource],
    boot: @escaping @Sendable () async -> Void,
    coder: CoderService? = nil,
    afterCoderServices: [any Service] = [],
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

    let coderServices: [any Service] = coder.map { [$0 as any Service] } ?? []
    let daemon = Daemon(
      services: Self.servicesWithLaneAdmissionLast(
        base: services + coderServices + afterCoderServices,
        laneAdmission: laneAdmission
      ),
      boot: boot,
      logger: logger,
      gracefulShutdownSignals: gracefulShutdownSignals,
      gracefulShutdownSeconds: Self.gracefulShutdownSeconds
    )

    return DaemonRuntimeBundle(
      daemon: daemon,
      lanes: coordination.lanes,
      credentialSources: credentialSources,
      laneShutdownOutcome: laneShutdownOutcome,
      coder: coder
    )
  }

  static func servicesWithLaneAdmissionLast(
    base: [any Service],
    laneAdmission: LaneAdmissionShutdownService
  ) -> [any Service] {
    base + [laneAdmission]
  }
}
