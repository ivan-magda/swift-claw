import ClawAgent
import ClawCore
import Foundation
import Logging
import ServiceLifecycle

/// The 60 s wall-clock ticker: scans due jobs, claims each through the store's fused
/// compare-and-advance (the per-occurrence overlap guard, backed by a per-session live-run skip
/// that serializes overlapping occurrences), applies the misfire table, and enqueues claimed fires
/// onto their job session's lane. Tick-level mutual exclusion is structural: one instance, one
/// sequential loop; cross-process exclusion is the startup flock.
public struct SchedulerService: Service {
  public static let tickInterval: Duration = .seconds(60)

  private let jobs: any ScheduledJobStore

  private let enqueuer: TurnEnqueuer
  private let policy: OccurrencePolicy

  private let catchUpMaxAge: Duration
  private let heartbeat: HeartbeatSettings

  private let workspace: any WorkspaceReading

  private let audit: any AuditLog

  private let now: @Sendable () -> Date
  private let clock: any Clock<Duration>

  private let logger: Logger

  private let skipEpisode = HeartbeatSkipEpisode()

  public init(
    jobs: any ScheduledJobStore,
    lanes: SessionLaneRegistry,
    turns: any TurnDispatching,
    calculator: OccurrenceCalculator,
    catchUpMaxAge: Duration,
    heartbeat: HeartbeatSettings,
    workspace: any WorkspaceReading,
    audit: any AuditLog,
    now: @escaping @Sendable () -> Date,
    clock: any Clock<Duration>,
    logger: Logger
  ) {
    self.jobs = jobs

    self.policy = OccurrencePolicy(calculator: calculator)
    self.catchUpMaxAge = catchUpMaxAge
    self.heartbeat = heartbeat

    self.workspace = workspace

    self.audit = audit

    self.now = now
    self.clock = clock

    self.logger = logger
    self.enqueuer = TurnEnqueuer(lanes: lanes, turns: turns, logger: logger)
  }

  public func run() async throws {
    logger.info("scheduler starting")
    await cancelWhenGracefulShutdown {
      // Tick immediately on start (restart recovery), then sleep between ticks.
      while !Task.isCancelled {
        await tick()
        do {
          try await clock.sleep(for: Self.tickInterval)
        } catch {
          break
        }
      }
    }
    logger.info("scheduler stopped")
  }

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

    await heartbeatIfDue(tickTime: tickTime)
  }
}

// MARK: - Job Firing

private extension SchedulerService {
  /// Cap on the misfire-count scan (observability only — the count feeds `jobMisfire` audit
  /// details, never control flow), so a months-old due date cannot enumerate unbounded dates.
  static let misfireCountLimit = 1_000

  /// The misfire lateness table for one due job — all wall clock, never tick counts.
  func fire(job: ScheduledJob, tickTime: Date) async {
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
      } else {
        fireAt = policy.coalescedFireTime(
          for: job,
          timezone: timezone,
          due: due,
          atOrBefore: tickTime
        )
      }

      guard
        let fire = try jobs.claimAndFire(
          jobId: job.id,
          due: due,
          fireAt: fireAt,
          nextOccurrence: policy.advance(
            for: job,
            timezone: timezone,
            anchor: due,
            after: tickTime
          ),
          now: tickTime
        )
      else {
        // No run to enqueue: the CAS matched no row (claimed elsewhere / job mutated) OR the
        // job's session already has a live run and the overlap guard skipped this fire.
        return
      }

      await enqueuer.enqueue(fire: fire)
    } catch {
      logger.error("scheduler fire failed for job \(job.id): \(error)")
    }
  }

  func skipMisfire(
    job: ScheduledJob,
    due: Date,
    timezone: TimeZone,
    tickTime: Date
  ) throws {
    let skippedCount = policy.missedOccurrenceCount(
      for: job,
      timezone: timezone,
      due: due,
      atOrBefore: tickTime,
      limit: Self.misfireCountLimit
    )

    _ = try jobs.skipMisfire(
      jobId: job.id,
      due: due,
      nextOccurrence: policy.advance(for: job, timezone: timezone, anchor: due, after: tickTime),
      skippedCount: skippedCount,
      now: tickTime
    )
  }
}

// MARK: - Heartbeat

private extension SchedulerService {
  /// HEARTBEAT.md consumable cap, in graphemes — the hand-curated-file precedent
  /// (`ContextBudget.default.memoryFileCap`): a checklist beyond it loads as `.overCap` with NO
  /// text (never silent truncation) and the beat skips before any LLM cost.
  static let heartbeatFileCapGraphemes = 2_200

  /// The heartbeat fire condition: enabled ∧ interval elapsed ∧ outside quiet hours ∧ under the
  /// daily cap ∧ HEARTBEAT.md usable. "Due" = enabled ∧ interval elapsed; only a DUE beat that
  /// skips is audited, so the audit trail stays quiet tick-to-tick.
  func heartbeatIfDue(tickTime: Date) async {
    guard heartbeat.enabled else {
      return  // default OFF ⇒ structurally inert: no state read, no audit, no cost
    }

    let state: SchedulerState
    do {
      state = try jobs.schedulerState()
    } catch {
      logger.error("heartbeat state read failed: \(error)")
      return
    }

    if let lastFired = state.lastHeartbeatAt {
      let intervalSeconds = Double(heartbeat.intervalMinutes) * 60
      guard tickTime.timeIntervalSince(lastFired) >= intervalSeconds else {
        await skipEpisode.end()  // not due — the next due skip is a NEW episode
        return
      }
    }

    guard let ownerChatId = heartbeat.ownerChatId else {
      // Unreachable when AppConfig validated the enabled+owner pair; fail closed, audibly.
      await auditHeartbeatSkip(reason: .disabledMidFlight, at: tickTime)
      return
    }
    guard heartbeat.quietHours.contains(tickTime, timezone: heartbeat.timezone) == false else {
      await auditHeartbeatSkip(reason: .quietHours, at: tickTime)
      return
    }

    // The cap's day boundary is the CLAW_TIMEZONE day string, aligned with quiet hours;
    // a stale stamp means the counter rolled over.
    let day = SchedulerHealth.dayString(for: tickTime, timezone: heartbeat.timezone)
    if state.heartbeatCountDay == day, state.heartbeatCount >= heartbeat.maxPerDay {
      await auditHeartbeatSkip(reason: .dailyCap, at: tickTime)
      return
    }

    let checklist = workspace.load(file: .heartbeat, maxGraphemes: Self.heartbeatFileCapGraphemes)
    let usableText = checklist.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard checklist.outcome == .present, usableText.isEmpty == false else {
      // BEFORE any LLM cost
      await auditHeartbeatSkip(reason: .emptyFile, at: tickTime)
      return
    }

    do {
      guard
        let fire = try jobs.fireHeartbeat(
          prompt: HeartbeatTemplate.prompt(checklist: checklist.text),
          ownerChatId: ownerChatId,
          now: tickTime,
          day: day
        )
      else {
        // A prior beat is still live: the store skipped this one to protect its window. Record
        // the canonical heartbeat_skipped audit (reason in `decision`) like every other beat skip.
        await auditHeartbeatSkip(reason: .overlap, at: tickTime)
        return
      }
      await skipEpisode.end()
      await enqueuer.enqueue(fire: fire)
    } catch {
      logger.error("heartbeat fire failed: \(error)")
    }
  }

  /// A skip changes no durable state, so its audit row stands alone (no co-transaction to
  /// ride). Deduped per EPISODE: a due heartbeat that keeps skipping for the same reason
  /// audits once, not once per 60 s tick — an 11-hour quiet window must not write ~660
  /// identical rows.
  func auditHeartbeatSkip(reason: HeartbeatSkipReason, at tickTime: Date) async {
    guard await skipEpisode.begin(reason) else {
      return  // same episode as the previous tick — already audited
    }
    do {
      try audit.appendAudit(
        AuditEvent(
          actor: .system,
          action: .heartbeatSkipped,
          decision: reason.rawValue,
          ts: tickTime
        )
      )
    } catch {
      logger.error("heartbeatSkipped audit failed: \(error)")
    }
  }
}

/// The reason a due heartbeat tick skipped a fire — one source of truth for the audit `decision`
/// string, so production and tests never re-type the bare literals.
enum HeartbeatSkipReason: String, Sendable {
  case disabledMidFlight = "disabled_mid_flight"
  case quietHours = "quiet_hours"
  case dailyCap = "daily_cap"
  case emptyFile = "empty_file"
  /// A prior beat's run on the heartbeat session is still live; firing would reset its window.
  case overlap
}

/// Dedupes consecutive heartbeat skip audits: one row per skip EPISODE — a run of consecutive
/// due ticks skipping for the same reason — because "due" stays true tick after tick until a
/// fire advances `last_heartbeat_at`. In-memory by design: a restart can re-audit one skip;
/// durable state for a diagnostic row is not worth a schema column. A reason CHANGE
/// (quiet_hours → daily_cap) starts a new episode and audits.
actor HeartbeatSkipEpisode {
  private var lastReason: HeartbeatSkipReason?

  /// True exactly when `reason` starts a new episode.
  func begin(_ reason: HeartbeatSkipReason) -> Bool {
    defer { lastReason = reason }
    return reason != lastReason
  }

  func end() {
    lastReason = nil
  }
}
