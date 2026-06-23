import ClawCore
import Logging
import ServiceLifecycle

/// The long-poll loop. Each batch runs through the router; the offset advances LAST and only
/// for durably-handled updates, so a transient failure re-polls instead of acking a lost echo.
/// Graceful shutdown cancels the task → the in-flight long poll unwinds and the loop exits.
public struct TelegramPollerService: Service {
  private let transport: any TelegramTransport
  private let router: MessageRouter
  private let cursor: any UpdateCursorStore
  private let pollTimeout: Int
  private let logger: Logger

  /// Re-sent on every call: omitting it would reuse the previous server-side setting. Only
  /// direct messages and edits are requested (no callback_query — no approvals yet).
  private static let allowedUpdates = ["message", "edited_message"]

  /// Back-off windows that stop a persistent fault from becoming a tight re-poll loop.
  private enum Backoff {
    static let transientFailure = Duration.seconds(2)
    static let conflict = Duration.seconds(10)
    static let otherError = Duration.seconds(3)
    static let storageFull = Duration.seconds(60)
  }

  public init(
    transport: any TelegramTransport,
    router: MessageRouter,
    cursor: any UpdateCursorStore,
    pollTimeout: Int,
    logger: Logger
  ) {
    self.transport = transport
    self.router = router
    self.cursor = cursor
    self.pollTimeout = pollTimeout
    self.logger = logger
  }

  public func run() async throws {
    logger.info("telegram poller starting")
    try await cancelWhenGracefulShutdown {
      while !Task.isCancelled {
        do {
          let offset = try cursor.loadCursor().map { $0 + 1 }
          let updates = try await transport.getUpdates(
            offset: offset,
            timeout: pollTimeout,
            allowedUpdates: Self.allowedUpdates
          )
          batch: for rawUpdate in updates {
            switch await router.handle(rawUpdate: rawUpdate) {
            case .processed, .skipped:
              try cursor.advanceCursor(to: rawUpdate.updateId)
            case .transientFailure:
              // Leave the offset untouched and re-poll the same window; the synchronous
              // claim dedups the redelivery. Stop the batch so later updates don't jump ahead.
              logger.warning(
                "transient failure on update \(rawUpdate.updateId); re-polling, not advancing"
              )
              try? await Task.sleep(for: Backoff.transientFailure)
              break batch
            case .storageFull:
              // Disk full: the user already got the notice. Back off long and don't advance, so we
              // re-poll once there's room rather than acking an update we couldn't durably handle.
              logger.error(
                "storage full on update \(rawUpdate.updateId); backing off, not advancing"
              )
              try? await Task.sleep(for: Backoff.storageFull)
              break batch
            }
          }
        } catch is CancellationError {
          break
        } catch let error as TelegramError {
          try await react(to: error)
        } catch {
          logger.error("poll loop error: \(error)")
          try? await Task.sleep(for: Backoff.otherError)
        }
      }
    }
    logger.info("telegram poller stopped")
  }

  private func react(to error: TelegramError) async throws {
    switch error {
    case .conflict409(let description):
      // The single-instance flock should prevent this locally; loud + bounded back-off otherwise.
      logger.critical("409 Conflict — another getUpdates consumer is active: \(description)")
      try? await Task.sleep(for: Backoff.conflict)
    case .floodControl(let retryAfter):
      logger.warning("429 flood control; backing off \(retryAfter)s")
      try? await Task.sleep(for: .seconds(retryAfter))
    case .apiError, .transport, .decoding:
      logger.error("telegram error: \(error)")
      try? await Task.sleep(for: Backoff.otherError)
    }
  }
}
