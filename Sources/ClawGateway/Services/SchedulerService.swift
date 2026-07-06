import ClawAgent
import ClawCore
import Foundation
import Logging
import ServiceLifecycle

/// The 60 s wall-clock ticker (spec §5): scans due jobs, claims each through the store's fused
/// compare-and-advance (the ONE overlap guard — §5.2), applies the misfire table (§5.3), and
/// enqueues claimed fires onto their job session's lane. Tick-level mutual exclusion is
/// structural: one instance, one sequential loop; cross-process exclusion is the startup flock.
public struct SchedulerService: Service {
  /// The tick grain (spec §5.3, pinned — not config): coarse enough to be negligible load, fine
  /// enough that an on-time fire lands within a minute of its occurrence. The misfire table's
  /// "lateness ≤ grain ⇒ on time" row is defined against this constant.
  public static let tickInterval: Duration = .seconds(60)

  /// Cap on the misfire-count scan (observability only — the count feeds `jobMisfire` audit
  /// details, never control flow), so a months-old due date cannot enumerate unbounded dates.
  static let misfireCountLimit = 1_000

  private let jobs: any ScheduledJobStore
  private let lanes: SessionLaneRegistry
  private let turns: any TurnDispatching
  private let calculator: OccurrenceCalculator
  private let catchUpMaxAge: Duration
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void
  private let logger: Logger

  public init(
    jobs: any ScheduledJobStore,
    lanes: SessionLaneRegistry,
    turns: any TurnDispatching,
    calculator: OccurrenceCalculator,
    catchUpMaxAge: Duration,
    now: @escaping @Sendable () -> Date,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    logger: Logger
  ) {
    self.jobs = jobs
    self.lanes = lanes
    self.turns = turns
    self.calculator = calculator
    self.catchUpMaxAge = catchUpMaxAge
    self.now = now
    self.sleep = sleep
    self.logger = logger
  }

  public func run() async throws {
    logger.info("scheduler starting")
    await cancelWhenGracefulShutdown {
      // Tick immediately on start (restart recovery — §5.1), then sleep between ticks.
      while !Task.isCancelled {
        await tick()
        do {
          try await sleep(Self.tickInterval)
        } catch {
          break
        }
      }
    }
    logger.info("scheduler stopped")
  }

  // MARK: - Load-bearing

  /// One scan-and-fire pass. Non-throwing by contract: the ticker must survive every store
  /// failure (a failed tick is retried by the next one) rather than crash the service group.
  func tick() async {
    let tickTime = now()
    do {
      try jobs.recordTick(at: tickTime)
    } catch {
      logger.error("scheduler recordTick failed: \(error)")
    }

    let dueJobs: [ScheduledJob]
    do {
      dueJobs = try jobs.dueJobs(now: tickTime)
    } catch {
      logger.error("scheduler due scan failed: \(error)")
      return
    }

    for job in dueJobs {
      await fire(job: job, tickTime: tickTime)
    }
  }

  /// The §5.3 lateness table for one due job — all wall clock, never tick counts.
  private func fire(job: ScheduledJob, tickTime: Date) async {
    guard let due = job.nextOccurrence else {
      return  // dueJobs' predicate makes this unreachable; defensive, never crash the ticker
    }
    guard let timezone = TimeZone(identifier: job.timezone) else {
      logger.error("job \(job.id) has an unresolvable timezone \(job.timezone); not firing")
      return
    }

    let lateness = tickTime.timeIntervalSince(due)
    let maxAgeSeconds = Double(catchUpMaxAge.components.seconds)

    do {
      if lateness >= maxAgeSeconds {
        try skipMisfire(job: job, due: due, timezone: timezone, tickTime: tickTime)
        return
      }

      let fireAt: Date
      if lateness <= Double(Self.tickInterval.components.seconds) {
        fireAt = due  // on time / one tick late
      } else if let envelope = job.recurrence {
        // Coalesce: N missed occurrences inside the window fire ONCE, at the latest missed
        // occurrence ≤ now; the CAS still matches the stored due (§5.2 — due vs T_fire).
        // Anchor = the stored due: every advance stays on the chain the confirm preview
        // showed (for everyNMinutes the phase is due + k·N; time-of-day rules are anchor-inert).
        fireAt =
          calculator.latestOccurrence(
            rule: envelope.rule,
            timezone: timezone,
            anchor: due,
            after: due.addingTimeInterval(-1),
            atOrBefore: tickTime
          ) ?? due
      } else {
        fireAt = due  // a one-shot has exactly one occurrence: the stored one
      }

      guard
        let fire = try jobs.claimAndFire(
          jobId: job.id,
          due: due,
          fireAt: fireAt,
          nextOccurrence: nextOccurrence(
            for: job,
            timezone: timezone,
            anchor: due,
            after: tickTime
          ),
          now: tickTime
        )
      else {
        return  // CAS matched no row: claimed elsewhere / job mutated — no fire
      }

      await enqueue(fire)
    } catch {
      logger.error("scheduler fire failed for job \(job.id): \(error)")
    }
  }

  private func skipMisfire(
    job: ScheduledJob,
    due: Date,
    timezone: TimeZone,
    tickTime: Date
  ) throws {
    let skippedCount =
      job.recurrence.map { envelope in
        calculator.occurrences(
          rule: envelope.rule,
          timezone: timezone,
          anchor: due,
          after: due.addingTimeInterval(-1),
          limit: Self.misfireCountLimit
        ).filter { occurrence in
          occurrence <= tickTime
        }.count
      } ?? 1

    _ = try jobs.skipMisfire(
      jobId: job.id,
      due: due,
      nextOccurrence: nextOccurrence(for: job, timezone: timezone, anchor: due, after: tickTime),
      skippedCount: skippedCount,
      now: tickTime
    )
  }

  /// The advanced next_occurrence: strictly after `after`; nil for a one-shot (→ COMPLETED).
  /// `anchor` is the occurrence being advanced from (the claimed/skipped due) — advances stay
  /// on the armed chain, so /schedule's confirm preview can never disagree with actual fires.
  private func nextOccurrence(
    for job: ScheduledJob,
    timezone: TimeZone,
    anchor: Date,
    after: Date
  ) -> Date? {
    job.recurrence.flatMap { envelope in
      calculator.occurrences(
        rule: envelope.rule,
        timezone: timezone,
        anchor: anchor,
        after: after,
        limit: 1
      ).first
    }
  }

  /// D1: a claimed fire is a first-class lane citizen — ordered and cancellable like any turn.
  private func enqueue(_ fire: ClaimedFire) async {
    let runner = turns
    let log = logger

    let lane = await lanes.actor(for: fire.sessionId)

    await lane.enqueue(runId: fire.runId) {
      do {
        try await runner.run(
          runId: fire.runId,
          sessionId: fire.sessionId,
          chatId: fire.ownerChatId,
          triggerMessageId: fire.triggerMessageId,
          grant: nil
        )
      } catch {
        // run() may throw only StoreError.diskFull; the lane closure cannot rethrow, so log it —
        // the PENDING run stays durable and boot reconciliation resolves it (§5.2).
        log.error("scheduled run \(fire.runId) failed with a storage error: \(error)")
      }
    }
  }
}
