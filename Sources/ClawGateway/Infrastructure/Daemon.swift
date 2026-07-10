import Logging
import ServiceLifecycle
import UnixSignals

/// Runs the injected service graph under a `ServiceGroup`, after a one-shot boot hook. The services
/// (poller, outbox dispatcher, …) are built at the `clawd` composition root and handed in, so the
/// daemon stays decoupled from concrete stores/transport. The graceful-shutdown signal set is a
/// parameter so tests can pass `[]` and cancel the task instead of raising a real signal.
public struct Daemon: Sendable {
  private let services: [any Service]
  private let boot: @Sendable () async -> Void
  private let logger: Logger
  private let gracefulShutdownSignals: [UnixSignal]
  private let gracefulShutdownSeconds: Int

  public init(
    services: [any Service],
    boot: @escaping @Sendable () async -> Void = {},
    logger: Logger,
    gracefulShutdownSignals: [UnixSignal] = [.sigterm, .sigint],
    gracefulShutdownSeconds: Int = 30
  ) {
    self.services = services
    self.boot = boot
    self.logger = logger
    self.gracefulShutdownSignals = gracefulShutdownSignals
    self.gracefulShutdownSeconds = gracefulShutdownSeconds
  }

  public func run() async throws {
    // One-shot boot reconciliation before serving: register the command menu and sweep orphaned
    // runs, so Telegram's state and the run table match this process before any update lands.
    await boot()

    // ServiceLifecycle logs the whole service graph at debug/trace. Floor its logger at .info so a
    // developer who sets CLAW_LOG_LEVEL=debug sees the app's request-lifecycle logs, not a large
    // framework graph dump. The app's own loggers keep the configured level (separate copies).
    var lifecycleLogger = logger
    lifecycleLogger.logLevel = max(logger.logLevel, .info)
    var configuration = ServiceGroupConfiguration(
      services: services,
      gracefulShutdownSignals: gracefulShutdownSignals,
      logger: lifecycleLogger
    )
    configuration.maximumGracefulShutdownDuration = .seconds(gracefulShutdownSeconds)

    try await ServiceGroup(configuration: configuration).run()
  }
}
