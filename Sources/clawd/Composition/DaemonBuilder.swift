import ClawCore
import ClawData
import ClawGateway
import ClawLLM
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

  let toolExecutor: AsyncHTTPExecutor

  let transport: TelegramClient
  let botUsername: String?

  let logger: Logger

  /// Builds the encrypted credential store the managed route loads its record from. A field rather
  /// than a literal so a composition test scripts a missing or malformed envelope in place of the
  /// real one; the current route never invokes it.
  let makeManagedStore: @Sendable () -> any LLMCredentialStore

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

    let workspace = FileSystemWorkspace(root: EnvironmentLoader.workspaceRoot(config: config))
    let agentStack = makeAgentStack(
      providerStack: providerStack,
      workspace: workspace,
      costResolver: costResolver,
      sandbox: sandbox
    )

    let turnRunner = makeTurnRunner(coordination: coordination, agentStack: agentStack)
    let approvalFabric = makeApprovalFabric(
      coordination: coordination,
      agentStack: agentStack,
      turnRunner: turnRunner
    )

    let scheduleSurface = makeScheduleSurface(
      providerStack: providerStack,
      costResolver: costResolver
    )
    let (poller, dispatcher) = makeIntakeServices(
      coordination: coordination,
      turnRunner: turnRunner,
      scheduleSurface: scheduleSurface,
      approvalCallbacks: approvalFabric.handler,
      doctor: DaemonDoctorReporter(stores: stores, config: config, sandbox: sandbox)
    )
    let (scheduler, heartbeatOwner) = makeScheduler(
      coordination: coordination,
      turnRunner: turnRunner,
      workspace: workspace
    )

    var services: [any Service] = [poller, dispatcher, scheduler, approvalFabric.expiry]
    if let maintenance = sandbox.maintenance {
      services.append(SandboxLifecycleService(maintenance: maintenance))
    }

    return runtimeBundle(
      services: services,
      coordination: coordination,
      // The shutdown bundle commits the rotation of the very source the provider authorized with:
      // one credential source, hoisted here from the stack the factory composed.
      credentialSource: providerStack.credentialSource,
      boot: bootSequence(
        coordination: coordination,
        waiter: approvalFabric.waiter,
        heartbeatOwner: heartbeatOwner
      )
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
