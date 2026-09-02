import ClawCore
import Foundation
import Logging
import ServiceLifecycle

/// Drives learning work off the owner delivery path. The lane tail notifies it after settlement;
/// the sweep and the boot pass are backstops for anything a crash lost between a settlement commit
/// and its notification. Every step it drives is idempotent, so a duplicate notification is free.
///
/// The sweep is the guarantee and the notification is the optimization, not the other way round: a
/// bound run reaches its terminal state on paths a lane closure can miss, and the queue read is
/// what makes those runs rejoin the loop without waiting for the next daemon start.
public actor ScheduledLearningService {
  /// A backstop cadence, not a latency budget — the lane tail already notifies on the ordinary
  /// path, so this only has to be faster than an owner notices a missing evaluation.
  public static let sweepInterval: Duration = .seconds(300)
  /// One sweep's bite of the unsealed queue. Bounds a single pass over a backlog a long outage
  /// built; the next tick takes the rest.
  private static let sweepBatchLimit = 64

  nonisolated private let store: any ScheduledLearningStore
  nonisolated private let clock: any Clock<Duration>
  nonisolated private let now: @Sendable () -> Date
  nonisolated private let logger: Logger

  private var pending: Set<Int64> = []
  /// The per-session lane's own pattern: a Swift actor does not serialize across `await`, so
  /// ordering between one drain and the next comes from chaining this task, not from isolation.
  private var drain: Task<Void, Never>?

  public init(
    store: any ScheduledLearningStore,
    clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger
  ) {
    self.store = store
    self.clock = clock
    self.now = now
    self.logger = logger
  }

  /// The lane tail's whole duty in one call: freeze the settled run's evidence, then queue its
  /// sealing.
  ///
  /// `nonisolated` so the settlement write runs on the lane's own thread and completes before the
  /// registry unregisters the operation. An actor hop would put a lane's settlement behind whatever
  /// sealing is already in flight, which is exactly the delivery-path coupling this service exists
  /// to avoid. The notification is sent whether or not this call was the one that froze the
  /// evidence: an ordinary DONE commit settles itself, and that run still has to be sealed.
  nonisolated public func settleAndNotify(runId: Int64, now: Date, log: Logger) async {
    do {
      try store.settleFromLane(runId: runId, now: now)
    } catch {
      log.error("run \(runId) settlement deferred to boot: \(error)")
    }
    await notifySettled(runId: runId)
  }

  public func notifySettled(runId: Int64) {
    pending.insert(runId)
    _ = kickDrain(now: now())
  }

  /// Three duties: seal what settled, reconcile open trials against their deadlines, and age data
  /// out. Trial reconciliation and retention join later; sealing is the one that ships here.
  public func sweep(now: Date) async {
    await sealSettled(now: now)
  }

  /// Runs after boot reconciliation has settled what the last process left open, so this pass sees
  /// those runs already frozen. It reads the durable queue and seals; it never settles a run
  /// itself, so it cannot disturb the ordering the boot sweep and its approval backstop rely on.
  public func reconcileAtBoot(now: Date) async {
    await sealSettled(now: now)
  }
}

// MARK: - Sealing Drain

private extension ScheduledLearningService {
  func sealSettled(now: Date) async {
    do {
      pending.formUnion(try store.unsealed(limit: Self.sweepBatchLimit))
    } catch {
      logger.error("learning sweep could not read the unsealed queue: \(error)")
    }
    await kickDrain(now: now).value
  }

  func kickDrain(now: Date) -> Task<Void, Never> {
    let previous = drain
    let task = Task {
      await previous?.value
      self.sealBatch(now: now)
    }
    drain = task
    return task
  }

  /// A run whose sealing throws stays in the durable unsealed queue, so the next sweep retries it
  /// rather than this pass holding the batch open.
  func sealBatch(now: Date) {
    let batch = pending.sorted()
    pending.removeAll()
    for runId in batch {
      do {
        try store.sealEvidence(runId: runId, now: now)
      } catch {
        logger.error("run \(runId) evidence sealing failed: \(error)")
      }
    }
  }
}

// MARK: - Sweep Ticker

extension ScheduledLearningService: Service {
  nonisolated public func run() async throws {
    logger.info("learning sweep starting")
    await cancelWhenGracefulShutdown {
      while !Task.isCancelled {
        await self.sweep(now: self.now())
        do {
          try await self.clock.sleep(for: Self.sweepInterval)
        } catch {
          break
        }
      }
    }
    logger.info("learning sweep stopped")
  }
}
