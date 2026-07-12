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

  func build() async -> Daemon {
    let sandbox = await prepareSandbox()
    let coordination = TurnCoordination()

    // Hoisted so the schedule draft parser and the agent share one provider instance.
    let provider = makeProvider()

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
      approvalCallbacks: approvalFabric.handler
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

    return Daemon(
      services: services,
      boot: bootSequence(
        coordination: coordination,
        waiter: approvalFabric.waiter,
        heartbeatOwner: heartbeatOwner
      ),
      logger: logger
    )
  }
}
