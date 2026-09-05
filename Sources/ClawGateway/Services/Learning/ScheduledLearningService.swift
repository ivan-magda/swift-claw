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

  nonisolated private let workflow: LearningWorkflow?
  nonisolated private let store: any ScheduledLearningStore
  nonisolated private let clock: any Clock<Duration>
  nonisolated private let now: @Sendable () -> Date
  nonisolated private let logger: Logger

  private var pending: Set<Int64> = []
  private var pendingJobs: Set<Int64> = []
  private var operationsReconciled = false
  private var sweepCursor: Int64 = 0
  /// The per-session lane's own pattern: a Swift actor does not serialize across `await`, so
  /// ordering between one drain and the next comes from chaining this task, not from isolation.
  private var drain: Task<Void, Never>?

  public init(
    store: any ScheduledLearningStore,
    workflow: LearningWorkflow? = nil,
    clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger
  ) {
    self.store = store
    self.workflow = workflow
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

  func waitForPendingWork() async {
    await drain?.value
  }

  public func notifyChanged(jobId: Int64) {
    pendingJobs.insert(jobId)
    _ = kickDrain(now: now())
  }

  public func advance(runId: Int64) async {
    guard ensureOperations(now: now()) else {
      return
    }
    if let workflow { await workflow.advance(runId: runId, now: now()) }
  }

  public func advance(jobId: Int64) async {
    guard ensureOperations(now: now()) else {
      return
    }
    if let workflow { await workflow.advance(jobId: jobId, now: now()) }
  }

  /// Seals settled runs, then reconciles live trials against their deadlines. Retention joins
  /// later; errors remain isolated so one bad row cannot starve later work.
  public func sweep(now: Date) async {
    if let workflow {
      guard ensureOperations(now: now) else {
        return
      }
      await sealSettled(now: now)
      do {
        let jobs = try workflow.store.workflowJobs(after: sweepCursor, limit: Self.sweepBatchLimit)
        sweepCursor = jobs.last ?? 0
        for jobId in jobs {
          do {
            let runs = try workflow.store.workflowRuns(
              jobId: jobId,
              after: 0,
              limit: Self.sweepBatchLimit
            )
            for runId in runs {
              await workflow.advance(runId: runId, now: now)
            }
            await workflow.advance(jobId: jobId, now: now)
          } catch {
            logger.error("job \(jobId) learning recovery deferred: \(error)")
          }
        }
      } catch {
        logger.error("learning workflow sweep deferred: \(error)")
      }
    } else {
      await sealSettled(now: now)
      _ = await reconcileTrials(now: now)
    }
  }

  /// Runs after boot reconciliation has settled what the last process left open, so this pass sees
  /// those runs already frozen. It reconciles operations, seals, then reconciles trials; it never
  /// settles a run itself, so it cannot disturb the boot sweep and approval-backstop ordering.
  ///
  /// The operation pass goes first, and no learning call may be dispatched before it returns: a
  /// prior process's `started` operation has to be charged and closed as unknown before anything
  /// re-reads headroom, and its claimed-but-never-authorized siblings have to become claimable
  /// again or the runs behind them are never evaluated.
  public func reconcileAtBoot(now: Date) async {
    let reconciled = ensureOperations(now: now)
    guard workflow == nil || reconciled else {
      return
    }
    await sweep(now: now)
  }

  @discardableResult
  public func reconcileTrials(now: Date) async -> [TrialReconciliation] {
    let identities: [LearningTrialIdentity]
    do {
      identities = try store.liveTrialIdentities()
    } catch {
      logger.error("learning sweep could not read live trials: \(error)")
      return []
    }

    var reconciliations: [TrialReconciliation] = []
    for identity in identities {
      do {
        switch try store.reconcileTrial(identity, now: now) {
        case .stale:
          break
        case .reconciled(let reconciliation):
          reconciliations.append(reconciliation)
        }
      } catch {
        logger.error("trial \(identity.trialId) reconciliation failed: \(error)")
      }
      await Task.yield()
    }
    return reconciliations
  }
}

// MARK: - Boot Operation Pass

private extension ScheduledLearningService {
  /// A failure here is logged and not thrown: the sealing pass and ordinary scheduled execution
  /// must still run when the learning tables cannot be reconciled.
  func ensureOperations(now: Date) -> Bool {
    if operationsReconciled { return true }
    operationsReconciled = reconcileOperations(now: now)
    return operationsReconciled
  }

  func reconcileOperations(now: Date) -> Bool {
    do {
      let result = try store.reconcileOperationsAtBoot(now: now)
      guard result.interrupted > 0 || result.returnedToClaimable > 0 else {
        return true
      }
      let closed = result.interrupted
      let requeued = result.returnedToClaimable
      logger.info("learning boot closed \(closed) interrupted, requeued \(requeued) unstarted")
      return true
    } catch {
      logger.error("learning operations could not be reconciled at boot: \(error)")
      return false
    }
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
      await self.sealBatch(now: now)
    }
    drain = task
    return task
  }

  /// A run whose sealing throws stays in the durable unsealed queue, so the next sweep retries it
  /// rather than this pass holding the batch open.
  ///
  /// The yield between runs is what keeps a lane out of the batch's way: each seal is a blocking
  /// store write, and without it a lane tail's `notifySettled` would queue behind up to a whole
  /// batch while its closure still holds the session lane. The snapshot and the clear stay adjacent
  /// with no suspension between them, so a notification that arrives mid-batch survives into the
  /// next drain rather than being dropped by the clear.
  func sealBatch(now: Date) async {
    guard workflow == nil || ensureOperations(now: now) else {
      return
    }
    let jobs = pendingJobs.sorted()
    pendingJobs.removeAll()
    let batch = pending.sorted()
    pending.removeAll()
    for runId in batch {
      do {
        if let workflow {
          await workflow.advance(runId: runId, now: now)
        } else {
          try store.sealEvidence(runId: runId, now: now)
        }
      } catch {
        logger.error("run \(runId) evidence sealing failed: \(error)")
      }
      await Task.yield()
    }
    for jobId in jobs {
      await workflow?.advance(jobId: jobId, now: now)
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
