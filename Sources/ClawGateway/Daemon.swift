import ClawCore
import Logging
import ServiceLifecycle
import UnixSignals

/// Composes the service graph and runs it under a ServiceGroup. Depends only on ClawCore
/// protocols — concrete stores are injected at the clawd composition root. The graceful-
/// shutdown signal set is a parameter so tests can pass `[]` and cancel the task instead.
public struct Daemon: Sendable {
  private let transport: any TelegramTransport
  private let processed: any ProcessedUpdateStore
  private let allowlist: any AllowlistStore
  private let cursor: any UpdateCursorStore
  private let pollTimeout: Int
  private let logger: Logger
  private let gracefulShutdownSignals: [UnixSignal]

  public init(
    transport: any TelegramTransport,
    processed: any ProcessedUpdateStore,
    allowlist: any AllowlistStore,
    cursor: any UpdateCursorStore,
    pollTimeout: Int,
    logger: Logger,
    gracefulShutdownSignals: [UnixSignal] = [.sigterm, .sigint]
  ) {
    self.transport = transport
    self.processed = processed
    self.allowlist = allowlist
    self.cursor = cursor
    self.pollTimeout = pollTimeout
    self.logger = logger
    self.gracefulShutdownSignals = gracefulShutdownSignals
  }

  public func run() async throws {
    let access = AccessControl(allowlist: allowlist)
    let router = MessageRouter(
      updateStore: processed,
      accessControl: access,
      transport: transport,
      logger: logger
    )
    let poller = TelegramPollerService(
      transport: transport,
      router: router,
      cursor: cursor,
      pollTimeout: pollTimeout,
      logger: logger
    )
    let group = ServiceGroup(
      services: [poller],
      gracefulShutdownSignals: gracefulShutdownSignals,
      logger: logger
    )
    try await group.run()
  }
}
