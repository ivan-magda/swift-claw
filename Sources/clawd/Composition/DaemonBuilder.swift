import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawTelegram
import ClawWorkspace
import Foundation
import Logging
import ServiceLifecycle

/// The composition root. Holds the cross-cutting inputs `run()` resolves before wiring — config,
/// secrets, stores, the two HTTP executors, the Telegram transport, and the logger — and `build()`
/// assembles the whole service graph from them: the OpenAI-compatible provider + agent feed a
/// `TurnRunner`, which the router dispatches from the poller. Both Telegram and the LLM share the
/// injected executor. The `make*` builders are organized by subsystem in `DaemonBuilder+*.swift`.
struct DaemonBuilder: Sendable {
  let config: AppConfig
  let secrets: Secrets
  let stores: ClawStores

  let executor: AsyncHTTPExecutor
  let toolExecutor: AsyncHTTPExecutor

  let transport: TelegramClient
  let botUsername: String?

  let logger: Logger

  /// The single production bound on both the ServiceGroup's graceful window and the lane drain, so
  /// admission-close, cancel, and the bounded drain all share one deadline.
  static let gracefulShutdownSeconds = 30

  func build() async throws -> DaemonRuntimeBundle {
    let sandbox = await prepareSandbox()
    let coordination = TurnCoordination()

    // Hoisted so the provider and the shutdown bundle share the SAME credential source: the shutdown
    // sequence commits the rotation of the very source every request authorized with.
    let credentialSource = StaticLLMCredentialSource(bearer: secrets.llmApiKey)

    // Hoisted so the schedule draft parser and the agent share one provider instance.
    let provider = makeProvider(credentials: credentialSource)

    // Hoisted so the agent and the /schedule parse share one offline-first cost resolver — both
    // meter spend against the same price snapshot and reference rate.
    let costResolver = CostResolver(
      priceTable: PriceFileLoader.load(),
      referenceUSDPerToken: config.budget.referenceUSDPerToken
    )

    let workspace = FileSystemWorkspace(root: EnvironmentLoader.workspaceRoot(config: config))
    let agentStack = makeAgentStack(
      provider: provider,
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

    let scheduleSurface = makeScheduleSurface(provider: provider, costResolver: costResolver)
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
      credentialSource: credentialSource,
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
