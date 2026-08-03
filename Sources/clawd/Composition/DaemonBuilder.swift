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

/// The composition root. Holds the cross-cutting inputs `run()` resolves before wiring — config,
/// secrets, stores, the dedicated tool executor, the Telegram transport, and the logger — plus the
/// lazy managed-store factory. `makeProviderStack` resolves the route into `any LLMProvider` on the
/// dedicated LLM executor, and `build(providerStack:)` assembles the whole service graph from it:
/// the provider + agent feed a `TurnRunner`, which the router dispatches from the poller. The `make*`
/// builders are organized by subsystem in `DaemonBuilder+*.swift`.
struct DaemonBuilder: Sendable {
  let config: AppConfig
  let secrets: Secrets
  let stores: ClawStores

  /// Protocol-typed rather than the concrete executor: every consumer — the two HTTP tools and each
  /// MCP transport — takes it through these seams, so a test can script the whole tool-side HTTP
  /// road without a socket.
  let toolExecutor: any HTTPExecuting & HTTPStreaming

  let transport: TelegramClient
  let botUsername: String?

  /// The owner's MCP catalog and the tokens bound to it, resolved before the logger existed so the
  /// tokens could join `redactionValues`.
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

  /// Resolves the configured route into a provider stack on the dedicated LLM executor. It supplies
  /// only inputs — the resolved route and settings, the lazy static bearer, the lazy managed store,
  /// the executor, and the build version — while the tested `ProviderStackFactory` in `ClawLLM` owns
  /// the selection. The static bearer is read only for the current route and the managed store built
  /// only for the ChatGPT route, so a route never opens the other's credential path. A malformed or
  /// insecure managed envelope throws the closed store taxonomy for the caller to map.
  func makeProviderStack(http: AsyncHTTPExecutor) throws -> ProviderStack {
    try ProviderStackFactory.make(
      route: config.llm.route,
      settings: config.llm,
      loadStaticBearer: { secrets.llmApiKey },
      makeManagedCredentialStore: makeManagedStore,
      http: http,
      buildVersion: ClawdVersion.current
    )
  }

  func build(providerStack: ProviderStack) async throws -> DaemonRuntimeBundle {
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
    let agentStack = makeAgentStack(
      providerStack: providerStack,
      workspace: workspace,
      costResolver: costResolver,
      sandbox: sandbox,
      mcpTools: mcpStack.tools
    )

    let consumers = makeRunnerConsumers(
      coordination: coordination,
      agentStack: agentStack,
      providerStack: providerStack,
      costResolver: costResolver,
      workspace: workspace,
      sandbox: sandbox,
      mcpCatalog: mcpStack.catalog
    )

    var services: [any Service] = [
      consumers.poller,
      consumers.outbox,
      consumers.scheduler,
      consumers.approvals.expiry,
    ]
    if let maintenance = sandbox.maintenance {
      services.append(SandboxLifecycleService(maintenance: maintenance))
    }
    if mcpStack.sessions.isEmpty == false {
      services.append(MCPSessionLifecycleService(sessions: mcpStack.sessions))
    }

    return runtimeBundle(
      services: services,
      coordination: coordination,
      // The shutdown bundle commits the rotation of the very source the provider authorized with:
      // one credential source, hoisted here from the stack the factory composed.
      credentialSource: providerStack.credentialSource,
      boot: bootSequence(
        coordination: coordination,
        waiter: consumers.approvals.waiter,
        heartbeatOwner: consumers.heartbeatOwner
      )
    )
  }

  /// Every service that copies the `TurnRunner` value — the router inside the poller, the approval
  /// waiter, and the scheduler.
  struct RunnerConsumers {
    let poller: TelegramPollerService
    let outbox: OutboxDispatcher
    let approvals: ApprovalFabric
    let scheduler: SchedulerService
    let heartbeatOwner: Int64?
  }

  /// Assembles those consumers in the one order that works, which is why they are built together
  /// rather than at four call sites: the runner goes in unnamed and comes back image-wired from the
  /// intake wiring, so nothing here can reach a copy that predates the cache an inbound photo lands
  /// in. A consumer holding such a copy replays no images and fails no test.
  func makeRunnerConsumers(  // swiftlint:disable:this function_parameter_count
    coordination: TurnCoordination,
    agentStack: AgentStack,
    providerStack: ProviderStack,
    costResolver: CostResolver,
    workspace: FileSystemWorkspace,
    sandbox: SandboxStack,
    mcpCatalog: ResolvedMCPCatalog
  ) -> RunnerConsumers {
    let intake = makeIntakeServices(
      coordination: coordination,
      turnRunner: makeTurnRunner(
        coordination: coordination,
        agentStack: agentStack,
        costPolicy: providerStack.costPolicy
      ),
      scheduleSurface: makeScheduleSurface(
        providerStack: providerStack,
        costResolver: costResolver
      ),
      approvalCallbacks: makeApprovalCallbackHandler(
        coordination: coordination,
        agentStack: agentStack
      ),
      doctor: DaemonDoctorReporter(
        stores: stores,
        config: config,
        sandbox: sandbox,
        staticAPIKey: secrets.llmApiKey,
        makeManagedStore: makeManagedStore,
        mcp: mcp,
        mcpOutcomes: mcpCatalog.outcomes
      )
    )
    let approvals = makeApprovalFabric(
      coordination: coordination,
      agentStack: agentStack,
      turnRunner: intake.turnRunner
    )
    let (scheduler, heartbeatOwner) = makeScheduler(
      coordination: coordination,
      turnRunner: intake.turnRunner,
      workspace: workspace
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
    credentialSource: any LLMCredentialSource,
    boot: @escaping @Sendable () async -> Void
  ) -> DaemonRuntimeBundle {
    let laneShutdownOutcome = LaneShutdownOutcome()
    let laneAdmission = LaneAdmissionShutdownService(
      lanes: coordination.lanes,
      outcome: laneShutdownOutcome,
      drainTimeout: .seconds(Self.gracefulShutdownSeconds),
      logger: logger
    )

    let daemon = Daemon(
      services: Self.servicesWithLaneAdmissionLast(base: services, laneAdmission: laneAdmission),
      boot: boot,
      logger: logger,
      gracefulShutdownSeconds: Self.gracefulShutdownSeconds
    )

    return DaemonRuntimeBundle(
      daemon: daemon,
      lanes: coordination.lanes,
      credentialSource: credentialSource,
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
