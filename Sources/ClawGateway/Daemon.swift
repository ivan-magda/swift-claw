import Logging
import ServiceLifecycle
import UnixSignals

/// Runs the injected service graph under a `ServiceGroup`, after a one-shot boot hook. The services
/// (poller, outbox dispatcher, …) are built at the `clawd` composition root and handed in, so the
/// daemon stays decoupled from concrete stores/transport. The graceful-shutdown signal set is a
/// parameter so tests can pass `[]` and cancel the task instead of raising a real signal.
public struct Daemon: Sendable {
  private let services: [any Service]
  private let bootReconcile: @Sendable () async -> Void
  private let logger: Logger
  private let gracefulShutdownSignals: [UnixSignal]
  private let gracefulShutdownSeconds: Int

  public init(
    services: [any Service],
    bootReconcile: @escaping @Sendable () async -> Void = {},
    logger: Logger,
    gracefulShutdownSignals: [UnixSignal] = [.sigterm, .sigint],
    gracefulShutdownSeconds: Int = 30
  ) {
    self.services = services
    self.bootReconcile = bootReconcile
    self.logger = logger
    self.gracefulShutdownSignals = gracefulShutdownSignals
    self.gracefulShutdownSeconds = gracefulShutdownSeconds
  }

  public func run() async throws {
    // Reconcile orphaned runs before serving (F22)
    await bootReconcile()

    var configuration = ServiceGroupConfiguration(
      services: services,
      gracefulShutdownSignals: gracefulShutdownSignals,
      logger: logger
    )
    configuration.maximumGracefulShutdownDuration = .seconds(gracefulShutdownSeconds)

    try await ServiceGroup(configuration: configuration).run()
  }
}
