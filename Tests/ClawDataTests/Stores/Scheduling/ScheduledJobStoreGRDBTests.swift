import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

// Cycle A-E `@Test` methods live in same-type extensions below purely to keep each extension's
// body under the project's `type_body_length` gate; this is still one `@Suite` with one set of
// shared fixtures/helpers declared here.
@Suite struct ScheduledJobStoreGRDBTests {
  // Whole-second fixtures: the store persists occurrence instants as epoch-second INTEGERs.
  private let baseNow = Date(timeIntervalSince1970: 1_782_000_000)
  private let dueFirst = Date(timeIntervalSince1970: 1_782_000_600)
  private let dueNext = Date(timeIntervalSince1970: 1_782_087_000)
  private let dueThird = Date(timeIntervalSince1970: 1_782_173_400)

  private func makeStore() throws -> (store: ScheduledJobStoreGRDB, queue: DatabaseQueue) {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return (ScheduledJobStoreGRDB(writer: queue), queue)
  }

  private func weekdayEnvelope() -> RecurrenceEnvelope {
    SchedulingRuleFixtures.weekdayEnvelope(zone: TimeZone(identifier: "Europe/Berlin") ?? .gmt)
  }

  @discardableResult
  private func makeJob(
    _ store: ScheduledJobStoreGRDB,
    recurrence: RecurrenceEnvelope?,
    next: Date,
    now: Date,
    label: String = "digest"
  ) throws -> ScheduledJob {
    try store.create(
      NewScheduledJob(
        ownerChatId: 777,
        label: label,
        prompt: "Summarize my unread items",
        recurrence: recurrence,
        timezone: "Europe/Berlin",
        nextOccurrence: next
      ),
      now: now
    )
  }

  private func count(
    _ queue: DatabaseQueue,
    sql: String,
    arguments: StatementArguments = StatementArguments()
  ) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: sql, arguments: arguments) ?? -1
    }
  }

  private func auditCount(_ queue: DatabaseQueue, action: AuditAction) throws -> Int {
    try count(
      queue,
      sql: "SELECT COUNT(*) FROM audit_events WHERE action = ?",
      arguments: [action.rawValue]
    )
  }

  /// Drives a fire's PENDING run to the terminal DONE state so the NEXT fire on that session no
  /// longer overlaps a live run. Consecutive proactive fires are only non-overlapping because the
  /// prior turn finished; the store enforces that, so these tests must model it explicitly.
  private func markRunDone(_ queue: DatabaseQueue, runId: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE runs SET state = ? WHERE id = ?",
        arguments: [RunState.done.rawValue, runId]
      )
    }
  }

  /// The `ClaimedFire` inside a `.fired` outcome, or nil for `.skippedActiveRun`/`.ineligible` —
  /// lets a test assert the case and reach the fire without an exhaustive switch each time.
  private func firedFire(_ outcome: RunNowOutcome) -> ClaimedFire? {
    guard case .fired(let fire) = outcome else {
      return nil
    }
    return fire
  }

  private func windowStart(_ queue: DatabaseQueue, sessionId: Int64) throws -> Int64? {
    try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT window_start_message_id FROM sessions WHERE id = ?",
        arguments: [sessionId]
      )
    }
  }
}

// MARK: - Cycle A: CRUD

extension ScheduledJobStoreGRDBTests {
  @Test func createRoundTripsTheJobRow() throws {
    // given
    let (store, _) = try makeStore()
    let envelope = weekdayEnvelope()

    // when
    let created = try makeJob(store, recurrence: envelope, next: dueFirst, now: baseNow)
    let fetched = try store.job(id: created.id)

    // then — the envelope survives the JSON column byte-for-byte enough to compare equal
    #expect(fetched == created)
    #expect(created.status == .active)
    #expect(created.recurrence == envelope)
    #expect(created.nextOccurrence == dueFirst)
    #expect(created.sessionId == nil)
    #expect(created.lastFiredAt == nil)
    #expect(created.createdTs == baseNow)
    #expect(created.updatedTs == baseNow)
    #expect(try store.job(id: created.id + 99) == nil)
  }

  @Test func oneShotRoundTripsWithNilRecurrence() throws {
    // given
    let (store, _) = try makeStore()

    // when
    let created = try makeJob(store, recurrence: nil, next: dueFirst, now: baseNow)

    // then
    #expect(try store.job(id: created.id)?.recurrence == nil)
  }

  @Test func listAllReturnsEveryRowInIdOrder() throws {
    // given
    let (store, _) = try makeStore()
    let first = try makeJob(store, recurrence: nil, next: dueFirst, now: baseNow, label: "a")
    let second = try makeJob(store, recurrence: nil, next: dueNext, now: baseNow, label: "b")

    // when / then
    #expect(try store.listAll().map(\.id) == [first.id, second.id])
  }

  @Test func dueJobsReturnsOnlyActiveDueRowsInDueOrder() throws {
    // given — two due (out of insert order), one future
    let (store, queue) = try makeStore()
    let later = try makeJob(
      store,
      recurrence: nil,
      next: Date(timeIntervalSince1970: 1_781_999_500),
      now: baseNow,
      label: "later-due"
    )
    let earlier = try makeJob(
      store,
      recurrence: nil,
      next: Date(timeIntervalSince1970: 1_781_999_000),
      now: baseNow,
      label: "earlier-due"
    )
    let future = try makeJob(
      store,
      recurrence: nil,
      next: Date(timeIntervalSince1970: 1_782_000_600),
      now: baseNow,
      label: "future"
    )

    // when / then — due-time order, not id order
    #expect(try store.dueJobs(now: baseNow).map(\.id) == [earlier.id, later.id])

    // and a non-ACTIVE row disappears from the scan even while due
    try queue.write { db in
      try db.execute(
        sql: "UPDATE scheduled_jobs SET status = ? WHERE id = ?",
        arguments: [ScheduledJobStatus.paused.rawValue, later.id]
      )
    }
    #expect(try store.dueJobs(now: baseNow).map(\.id) == [earlier.id])

    // and a NULL next_occurrence row does too
    try queue.write { db in
      try db.execute(
        sql: "UPDATE scheduled_jobs SET next_occurrence = NULL WHERE id = ?",
        arguments: [earlier.id]
      )
    }
    #expect(try store.dueJobs(now: baseNow).isEmpty)
    _ = future  // silences the unused-binding warning; the row proves the <= now bound
  }
}

// MARK: - Cycle B: the fused claim (KEYSTONE)

extension ScheduledJobStoreGRDBTests {
  @Test func staleDueClaimLosesAfterTheFirstAdvance() throws {
    // given — two claims for the same (job, due): the second models a racing ticker that read
    // the row before the first advanced it
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)
    let fireTime = dueFirst.addingTimeInterval(30)

    // when
    let winner = try store.claimAndFire(
      jobId: job.id,
      due: dueFirst,
      fireAt: dueFirst,
      nextOccurrence: dueNext,
      now: fireTime
    )
    let loser = try store.claimAndFire(
      jobId: job.id,
      due: dueFirst,
      fireAt: dueFirst,
      nextOccurrence: dueNext,
      now: fireTime
    )

    // then — exactly one fire: one run row, next_occurrence advanced exactly once
    #expect(winner != nil)
    #expect(loser == nil)
    #expect(try count(queue, sql: "SELECT COUNT(*) FROM runs") == 1)
    let after = try store.job(id: job.id)
    #expect(after?.nextOccurrence == dueNext)
    #expect(after?.lastFiredAt == dueFirst)
    #expect(after?.status == .active)
    #expect(try auditCount(queue, action: .jobExecuted) == 1)
  }

  @Test func concurrentClaimsAllowExactlyOneWinner() async throws {
    // given — a real writer race on a file-backed WAL pool, not the serialized test queue
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-sched-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pool = try ClawDatabase.makePool(
      path: directory.appendingPathComponent("claw.sqlite").path
    )
    try ClawDatabase.migrate(pool)
    let store = ScheduledJobStoreGRDB(writer: pool)
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)
    let fireTime = dueFirst.addingTimeInterval(30)
    let claimDue = dueFirst
    let claimNext = dueNext

    // when — two tasks race the same (job, due)
    let claims = await withTaskGroup(of: ClaimedFire?.self) { group in
      for _ in 0..<2 {
        group.addTask {
          try? store.claimAndFire(
            jobId: job.id,
            due: claimDue,
            fireAt: claimDue,
            nextOccurrence: claimNext,
            now: fireTime
          )
        }
      }
      var collected: [ClaimedFire?] = []
      for await claim in group {
        collected.append(claim)
      }
      return collected
    }

    // then — exactly one winner AND exactly one run row (a swallowed error cannot fake this:
    // zero fires would leave zero runs and zero winners; two would leave two)
    #expect(claims.compactMap { claim in claim }.count == 1)
    let runCount = try await pool.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs") ?? -1
    }
    #expect(runCount == 1)
    #expect(try store.job(id: job.id)?.nextOccurrence == dueNext)
  }

  @Test func oneShotClaimCompletesTheJob() throws {
    // given
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: nil, next: dueFirst, now: baseNow)

    // when — nextOccurrence nil ⇒ one-shot terminal transition
    let claimed = try store.claimAndFire(
      jobId: job.id,
      due: dueFirst,
      fireAt: dueFirst,
      nextOccurrence: nil,
      now: dueFirst
    )
    let replay = try store.claimAndFire(
      jobId: job.id,
      due: dueFirst,
      fireAt: dueFirst,
      nextOccurrence: nil,
      now: dueFirst
    )

    // then — COMPLETED, NULL next, invisible to the ticker, unrepeatable
    #expect(claimed != nil)
    #expect(replay == nil)
    let after = try store.job(id: job.id)
    #expect(after?.status == .completed)
    #expect(after?.nextOccurrence == nil)
    #expect(try store.dueJobs(now: dueNext).isEmpty)
    #expect(try count(queue, sql: "SELECT COUNT(*) FROM runs") == 1)
  }

  @Test func firstClaimLazilyCreatesTheJobSessionThenReusesIt() throws {
    // given
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)

    // when — two consecutive, non-overlapping fires (the first run completes before the second)
    let first = try store.claimAndFire(
      jobId: job.id,
      due: dueFirst,
      fireAt: dueFirst,
      nextOccurrence: dueNext,
      now: dueFirst
    )
    let firstFire = try #require(first)
    try markRunDone(queue, runId: firstFire.runId)
    let second = try store.claimAndFire(
      jobId: job.id,
      due: dueNext,
      fireAt: dueNext,
      nextOccurrence: dueThird,
      now: dueNext
    )

    // then — one dedicated session, reused; runs carry origin + job linkage; the trigger
    // message is the owner's own confirmed prompt at the trusted tier (spec §5.2)
    let secondFire = try #require(second)
    #expect(firstFire.sessionId == secondFire.sessionId)
    #expect(firstFire.triggerMessageId != secondFire.triggerMessageId)
    #expect(firstFire.ownerChatId == 777)
    #expect(
      try count(
        queue,
        sql: "SELECT COUNT(*) FROM sessions WHERE session_key = ?",
        arguments: [SessionKey.scheduledJob(id: job.id)]
      ) == 1
    )
    #expect(try store.job(id: job.id)?.sessionId == firstFire.sessionId)
    // Both fires produced a scheduled run linked to the job (the first since driven to DONE, the
    // second freshly PENDING) — the second was allowed only because the first was terminal.
    #expect(
      try count(
        queue,
        sql: "SELECT COUNT(*) FROM runs WHERE origin = ? AND job_id = ?",
        arguments: [RunOrigin.scheduled.rawValue, job.id]
      ) == 2
    )
    #expect(
      try count(
        queue,
        sql: "SELECT COUNT(*) FROM runs WHERE origin = ? AND job_id = ? AND state = ?",
        arguments: [RunOrigin.scheduled.rawValue, job.id, RunState.pending.rawValue]
      ) == 1
    )
    #expect(
      try count(
        queue,
        sql: """
          SELECT COUNT(*) FROM messages
          WHERE role = 'user' AND provenance = 'trusted' AND content = 'Summarize my unread items'
          """
      ) == 2
    )
  }
}

// MARK: - Cycle C: scheduler_state, run-now, misfire

extension ScheduledJobStoreGRDBTests {
  @Test func schedulerStateStartsEmptyAndRecordTickUpserts() throws {
    // given
    let (store, _) = try makeStore()

    // when / then — no row yet reads as the zero state
    #expect(
      try store.schedulerState()
        == SchedulerState(
          lastTickAt: nil,
          lastMisfireAt: nil,
          lastMisfireSkippedCount: 0,
          lastHeartbeatAt: nil,
          heartbeatCountDay: nil,
          heartbeatCount: 0
        )
    )

    // when — two ticks upsert the same singleton row
    try store.recordTick(at: baseNow)
    let laterTick = baseNow.addingTimeInterval(60)
    try store.recordTick(at: laterTick)

    // then
    let state = try store.schedulerState()
    #expect(state.lastTickAt == laterTick)
    #expect(state.lastMisfireAt == nil)
    #expect(state.heartbeatCount == 0)
  }

  @Test func fireNowFiresWithoutTouchingTheSchedule() throws {
    // given
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)

    // when
    let outcome = try store.fireNow(jobId: job.id, now: baseNow)

    // then — a real fire (run + audit + last_fired_at) with the schedule untouched (spec §5.4)
    #expect(firedFire(outcome) != nil)
    let after = try store.job(id: job.id)
    #expect(after?.nextOccurrence == dueFirst)
    #expect(after?.status == .active)
    #expect(after?.lastFiredAt == baseNow)
    #expect(
      try count(
        queue,
        sql: "SELECT COUNT(*) FROM runs WHERE origin = ? AND job_id = ?",
        arguments: [RunOrigin.scheduled.rawValue, job.id]
      ) == 1
    )
    #expect(try auditCount(queue, action: .jobExecuted) == 1)
  }

  @Test func fireNowRequiresActiveOrPaused() throws {
    // given — PAUSED is allowed (test a job without unmuting it, spec §5.4); terminal is not
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)
    try queue.write { db in
      try db.execute(
        sql: "UPDATE scheduled_jobs SET status = ? WHERE id = ?",
        arguments: [ScheduledJobStatus.paused.rawValue, job.id]
      )
    }

    // when / then — fires on PAUSED without changing the status
    #expect(firedFire(try store.fireNow(jobId: job.id, now: baseNow)) != nil)
    #expect(try store.job(id: job.id)?.status == .paused)

    // and refuses terminal states and absent ids
    try queue.write { db in
      try db.execute(
        sql: "UPDATE scheduled_jobs SET status = ?, next_occurrence = NULL WHERE id = ?",
        arguments: [ScheduledJobStatus.cancelled.rawValue, job.id]
      )
    }
    #expect(try store.fireNow(jobId: job.id, now: baseNow) == .ineligible)
    #expect(try store.fireNow(jobId: job.id + 99, now: baseNow) == .ineligible)
  }

  @Test func skipMisfireAdvancesWithNoRunAndAuditsTheSkip() throws {
    // given
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)
    let skipTime = dueFirst.addingTimeInterval(3_600)

    // when — five occurrences fell out of the catch-up window
    let applied = try store.skipMisfire(
      jobId: job.id,
      due: dueFirst,
      nextOccurrence: dueNext,
      skippedCount: 5,
      now: skipTime
    )
    let stale = try store.skipMisfire(
      jobId: job.id,
      due: dueFirst,
      nextOccurrence: dueNext,
      skippedCount: 5,
      now: skipTime
    )

    // then — advanced, no run, nothing "fired", misfire state + audit written
    #expect(applied)
    #expect(stale == false)
    #expect(try count(queue, sql: "SELECT COUNT(*) FROM runs") == 0)
    let after = try store.job(id: job.id)
    #expect(after?.nextOccurrence == dueNext)
    #expect(after?.lastFiredAt == nil)
    let state = try store.schedulerState()
    #expect(state.lastMisfireAt == skipTime)
    #expect(state.lastMisfireSkippedCount == 5)
    #expect(try auditCount(queue, action: .jobMisfire) == 1)
  }

  /// The fire claim and the misfire skip advance the occurrence through one compare-and-advance, so
  /// they race each other, not only their own kind. A ticker that decided to skip while another
  /// decided to fire must not do both to the same occurrence.
  @Test func aMisfireSkipLosesToAFireClaimOnTheSameOccurrence() throws {
    // given
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)

    // when — the claim advances first, then a skip arrives holding the same stale due
    let claimed = try store.claimAndFire(
      jobId: job.id,
      due: dueFirst,
      fireAt: dueFirst,
      nextOccurrence: dueNext,
      now: dueFirst
    )
    let skipped = try store.skipMisfire(
      jobId: job.id,
      due: dueFirst,
      nextOccurrence: dueNext,
      skippedCount: 3,
      now: dueFirst.addingTimeInterval(60)
    )

    // then — the fire stands and the skip changed nothing, state and audit included
    #expect(claimed != nil)
    #expect(skipped == false)
    let after = try store.job(id: job.id)
    #expect(after?.nextOccurrence == dueNext)
    #expect(after?.lastFiredAt == dueFirst)
    #expect(try count(queue, sql: "SELECT COUNT(*) FROM runs") == 1)
    #expect(try auditCount(queue, action: .jobMisfire) == 0)
    #expect(try store.schedulerState().lastMisfireAt == nil)
  }

  @Test func skipMisfireCompletesAOneShot() throws {
    // given — a one-shot whose single occurrence aged out entirely
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: nil, next: dueFirst, now: baseNow)

    // when
    let applied = try store.skipMisfire(
      jobId: job.id,
      due: dueFirst,
      nextOccurrence: nil,
      skippedCount: 1,
      now: dueNext
    )

    // then
    #expect(applied)
    let after = try store.job(id: job.id)
    #expect(after?.status == .completed)
    #expect(after?.nextOccurrence == nil)
    #expect(try count(queue, sql: "SELECT COUNT(*) FROM runs") == 0)
  }
}

// MARK: - Cycle D: verb semantics (spec §5.4, §4.1 FSM)

extension ScheduledJobStoreGRDBTests {
  @Test func pauseIsIdempotentAndHidesTheJobFromTheTicker() throws {
    // given
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)

    // when
    let paused = try store.pause(id: job.id, now: baseNow)
    let pausedAgain = try store.pause(id: job.id, now: baseNow)

    // then — PAUSED, invisible to the scan, idempotent with a single audit row
    #expect(paused?.status == .paused)
    #expect(pausedAgain?.status == .paused)
    #expect(try store.dueJobs(now: dueNext).isEmpty)
    #expect(try auditCount(queue, action: .jobPaused) == 1)
    #expect(try store.pause(id: job.id + 99, now: baseNow) == nil)
  }

  @Test func resumeAppliesTheCallerRecomputedNextOccurrence() throws {
    // given — pause = "be quiet", not "queue up": the caller recomputes from now, so
    // occurrences inside the paused window are skipped, never caught up (spec §5.4)
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)
    _ = try store.pause(id: job.id, now: baseNow)

    // when
    let resumed = try store.resume(id: job.id, nextOccurrence: dueThird, now: dueNext)
    let resumedAgain = try store.resume(id: job.id, nextOccurrence: dueFirst, now: dueNext)

    // then — ACTIVE at the recomputed occurrence; a second resume is a no-op (no re-aim)
    #expect(resumed?.status == .active)
    #expect(resumed?.nextOccurrence == dueThird)
    #expect(resumedAgain?.status == .active)
    #expect(resumedAgain?.nextOccurrence == dueThird)
    #expect(try auditCount(queue, action: .jobResumed) == 1)
  }

  @Test func cancelIsTerminalAndRetainsTheRow() throws {
    // given
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)

    // when
    let cancelled = try store.cancel(id: job.id, now: baseNow)
    let cancelledAgain = try store.cancel(id: job.id, now: baseNow)

    // then — CANCELLED with NULL next, row retained for audit, no exit from terminal
    #expect(cancelled?.status == .cancelled)
    #expect(cancelled?.nextOccurrence == nil)
    #expect(cancelledAgain == nil)
    #expect(try store.job(id: job.id) != nil)
    #expect(try store.dueJobs(now: dueNext).isEmpty)
    #expect(try auditCount(queue, action: .jobCancelled) == 1)
    // terminal states refuse every verb and every fire path
    #expect(try store.pause(id: job.id, now: baseNow) == nil)
    #expect(try store.resume(id: job.id, nextOccurrence: dueNext, now: baseNow) == nil)
    #expect(try store.fireNow(jobId: job.id, now: baseNow) == .ineligible)
    #expect(
      try store.claimAndFire(
        jobId: job.id,
        due: dueFirst,
        fireAt: dueFirst,
        nextOccurrence: dueNext,
        now: baseNow
      ) == nil
    )
  }

  @Test func cancelAppliesFromPausedToo() throws {
    // given
    let (store, _) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)
    _ = try store.pause(id: job.id, now: baseNow)

    // when / then
    #expect(try store.cancel(id: job.id, now: baseNow)?.status == .cancelled)
  }
}

// MARK: - Cycle E: heartbeat fire + conformance

extension ScheduledJobStoreGRDBTests {
  @Test func fireHeartbeatCreatesTheHeartbeatRunOnItsOwnSession() throws {
    // given
    let (store, queue) = try makeStore()

    // when
    let fired = try #require(
      try store.fireHeartbeat(
        prompt: "Review the checklist below…",
        ownerChatId: 777,
        now: baseNow,
        day: "2026-07-06"
      )
    )

    // then — dedicated persistent session; origin heartbeat; NO job linkage; the template
    // wraps HEARTBEAT.md content, so the trigger rides the UNTRUSTED tier (spec §12)
    #expect(fired.ownerChatId == 777)
    #expect(
      try count(
        queue,
        sql: "SELECT COUNT(*) FROM sessions WHERE session_key = ?",
        arguments: [SessionKey.heartbeat]
      ) == 1
    )
    #expect(
      try count(
        queue,
        sql: "SELECT COUNT(*) FROM runs WHERE origin = ? AND job_id IS NULL AND state = ?",
        arguments: [RunOrigin.heartbeat.rawValue, "PENDING"]
      ) == 1
    )
    #expect(
      try count(
        queue,
        sql: "SELECT COUNT(*) FROM messages WHERE role = 'user' AND provenance = 'untrusted'"
      ) == 1
    )
    let state = try store.schedulerState()
    #expect(state.lastHeartbeatAt == baseNow)
    #expect(state.heartbeatCountDay == "2026-07-06")
    #expect(state.heartbeatCount == 1)
  }

  @Test func heartbeatDayCounterRollsAtTheDayBoundary() throws {
    // given
    let (store, queue) = try makeStore()
    let secondFire = baseNow.addingTimeInterval(3_600)
    let nextDayFire = baseNow.addingTimeInterval(86_400)

    // when — each beat completes before the next fires (consecutive beats never overlap; the
    // store would otherwise skip a fire into a still-live beat)
    let firstBeat = try #require(
      try store.fireHeartbeat(prompt: "check", ownerChatId: 777, now: baseNow, day: "2026-07-06")
    )
    try markRunDone(queue, runId: firstBeat.runId)
    let secondBeat = try #require(
      try store.fireHeartbeat(
        prompt: "check",
        ownerChatId: 777,
        now: secondFire,
        day: "2026-07-06"
      )
    )
    try markRunDone(queue, runId: secondBeat.runId)
    let sameDayState = try store.schedulerState()
    let thirdBeat = try #require(
      try store.fireHeartbeat(
        prompt: "check",
        ownerChatId: 777,
        now: nextDayFire,
        day: "2026-07-07"
      )
    )
    try markRunDone(queue, runId: thirdBeat.runId)
    let nextDayState = try store.schedulerState()

    // then — the cap's day boundary is the caller's CLAW_TIMEZONE day string, not UTC (spec §4.3)
    #expect(sameDayState.heartbeatCount == 2)
    #expect(nextDayState.heartbeatCountDay == "2026-07-07")
    #expect(nextDayState.heartbeatCount == 1)
    #expect(nextDayState.lastHeartbeatAt == nextDayFire)
    // and the session is reused, never duplicated
    #expect(
      try count(
        queue,
        sql: "SELECT COUNT(*) FROM sessions WHERE session_key = ?",
        arguments: [SessionKey.heartbeat]
      ) == 1
    )
  }
}

// MARK: - Cycle F: per-fire context isolation

extension ScheduledJobStoreGRDBTests {
  @Test func eachFireResetsTheSessionWindowSoPriorTurnsStayOutOfContext() throws {
    // given — a first fire whose turn left a poisoned exchange and sticky flags behind
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)
    let firstFire = try #require(
      try store.claimAndFire(
        jobId: job.id,
        due: dueFirst,
        fireAt: dueFirst,
        nextOccurrence: dueNext,
        now: dueFirst
      )
    )
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts)
          VALUES (?, 'assistant', 'That text needs to be sent as a /schedule command', 'trusted', ?)
          """,
        arguments: [firstFire.sessionId, dueFirst]
      )
      try db.execute(
        sql: "UPDATE sessions SET tainted = 1, has_private_data = 1 WHERE id = ?",
        arguments: [firstFire.sessionId]
      )
    }
    // The first run finishes; only then is the next fire non-overlapping and allowed to reset.
    try markRunDone(queue, runId: firstFire.runId)

    // when — the next fire claims on the same persistent session
    let secondFire = try #require(
      try store.claimAndFire(
        jobId: job.id,
        due: dueNext,
        fireAt: dueNext,
        nextOccurrence: dueThird,
        now: dueNext
      )
    )

    // then — same session, but the snapshot holds only the new trigger and the flags cleared
    #expect(secondFire.sessionId == firstFire.sessionId)
    let snapshot = try SessionMessageStoreGRDB(writer: queue).loadContextSnapshot(
      sessionId: secondFire.sessionId,
      throughMessageId: secondFire.triggerMessageId,
      limit: 50
    )
    #expect(snapshot.history.map(\.content) == ["Summarize my unread items"])
    #expect(snapshot.isTainted == false)
    #expect(snapshot.hasPrivateData == false)
  }

  @Test func eachHeartbeatFireResetsTheHeartbeatSessionWindow() throws {
    // given — a prior, now-completed beat left a reply on the shared heartbeat session
    let (store, queue) = try makeStore()
    let firstBeat = try #require(
      try store.fireHeartbeat(
        prompt: "beat one",
        ownerChatId: 777,
        now: baseNow,
        day: "2026-07-13"
      )
    )
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts)
          VALUES (?, 'assistant', 'HEARTBEAT_OK', 'trusted', ?)
          """,
        arguments: [firstBeat.sessionId, baseNow]
      )
    }
    try markRunDone(queue, runId: firstBeat.runId)

    // when
    let secondBeat = try #require(
      try store.fireHeartbeat(
        prompt: "beat two",
        ownerChatId: 777,
        now: dueFirst,
        day: "2026-07-14"
      )
    )

    // then — the new beat's snapshot carries only its own trigger
    #expect(secondBeat.sessionId == firstBeat.sessionId)
    let snapshot = try SessionMessageStoreGRDB(writer: queue).loadContextSnapshot(
      sessionId: secondBeat.sessionId,
      throughMessageId: secondBeat.triggerMessageId,
      limit: 50
    )
    #expect(snapshot.history.map(\.content) == ["beat two"])
  }
}

// MARK: - Cycle G: overlapping fires skipped while a prior run is live

extension ScheduledJobStoreGRDBTests {
  @Test func overlappingJobFireIsSkippedWhileThePriorRunIsLive() throws {
    // given — a first fire whose PENDING run is still live (parked, e.g. on an approval)
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)
    let firstFire = try #require(
      try store.claimAndFire(
        jobId: job.id,
        due: dueFirst,
        fireAt: dueFirst,
        nextOccurrence: dueNext,
        now: dueFirst
      )
    )
    let windowBeforeSecond = try windowStart(queue, sessionId: firstFire.sessionId)

    // when — the next occurrence claims while the prior run is still live
    let secondFire = try store.claimAndFire(
      jobId: job.id,
      due: dueNext,
      fireAt: dueNext,
      nextOccurrence: dueThird,
      now: dueNext
    )

    // then — skipped: nil returned, no second run, the window did not advance past the parked
    // run's rows, and the skip is audited
    #expect(secondFire == nil)
    #expect(
      try count(
        queue,
        sql: "SELECT COUNT(*) FROM runs WHERE session_id = ?",
        arguments: [firstFire.sessionId]
      ) == 1
    )
    #expect(try windowStart(queue, sessionId: firstFire.sessionId) == windowBeforeSecond)
    #expect(try auditCount(queue, action: .jobOverlapSkipped) == 1)

    // and last_fired_at still records the prior REAL fire (dueFirst), not the skipped occurrence's
    // fireAt (dueNext) — a skip creates no run, so it must not move the fire clock
    #expect(try store.job(id: job.id)?.lastFiredAt == dueFirst)

    // and the parked run's trigger is still inside its context window
    let snapshot = try SessionMessageStoreGRDB(writer: queue).loadContextSnapshot(
      sessionId: firstFire.sessionId,
      throughMessageId: firstFire.triggerMessageId,
      limit: 50
    )
    #expect(snapshot.history.map(\.content) == ["Summarize my unread items"])
  }

  @Test func onceThePriorRunIsTerminalTheNextFireProceedsAndResets() throws {
    // given — a first fire whose run has since reached the terminal DONE state
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)
    let firstFire = try #require(
      try store.claimAndFire(
        jobId: job.id,
        due: dueFirst,
        fireAt: dueFirst,
        nextOccurrence: dueNext,
        now: dueFirst
      )
    )
    try markRunDone(queue, runId: firstFire.runId)

    // when — the next occurrence fires with no live run to guard against
    let secondFire = try store.claimAndFire(
      jobId: job.id,
      due: dueNext,
      fireAt: dueNext,
      nextOccurrence: dueThird,
      now: dueNext
    )

    // then — it proceeds (fresh run) and its window resets so the prior trigger is out of context
    let resumedFire = try #require(secondFire)
    #expect(resumedFire.sessionId == firstFire.sessionId)
    #expect(try auditCount(queue, action: .jobOverlapSkipped) == 0)
    // a real (non-overlap) fire DOES advance the fire clock to its fireAt
    #expect(try store.job(id: job.id)?.lastFiredAt == dueNext)
    let snapshot = try SessionMessageStoreGRDB(writer: queue).loadContextSnapshot(
      sessionId: resumedFire.sessionId,
      throughMessageId: resumedFire.triggerMessageId,
      limit: 50
    )
    #expect(snapshot.history.map(\.content) == ["Summarize my unread items"])
  }

  @Test func overlappingHeartbeatFireIsSkippedWhileThePriorBeatIsLive() throws {
    // given — a first beat whose PENDING run is still live
    let (store, queue) = try makeStore()
    let firstBeat = try #require(
      try store.fireHeartbeat(
        prompt: "beat one",
        ownerChatId: 777,
        now: baseNow,
        day: "2026-07-13"
      )
    )
    let windowBeforeSecond = try windowStart(queue, sessionId: firstBeat.sessionId)

    // when — a second beat fires while the first is still live
    let secondBeat = try store.fireHeartbeat(
      prompt: "beat two",
      ownerChatId: 777,
      now: dueFirst,
      day: "2026-07-14"
    )

    // then — skipped: nil returned, no second run, window unchanged. The store itself writes NO
    // skip audit; nil is the whole signal (the gateway records the heartbeat_skipped audit with
    // the reason in `decision`, matching every other beat skip).
    #expect(secondBeat == nil)
    #expect(
      try count(
        queue,
        sql: "SELECT COUNT(*) FROM runs WHERE session_id = ?",
        arguments: [firstBeat.sessionId]
      ) == 1
    )
    #expect(try windowStart(queue, sessionId: firstBeat.sessionId) == windowBeforeSecond)
    #expect(try auditCount(queue, action: .heartbeatSkipped) == 0)
  }

  @Test func runNowIsSkippedWithItsOwnOutcomeWhileThePriorRunIsLive() throws {
    // given — a job whose first fire left a live PENDING run
    let (store, queue) = try makeStore()
    let job = try makeJob(store, recurrence: weekdayEnvelope(), next: dueFirst, now: baseNow)
    let firstFire = try #require(firedFire(try store.fireNow(jobId: job.id, now: baseNow)))
    let windowBeforeSecond = try windowStart(queue, sessionId: firstFire.sessionId)

    // when — /runnow fires again while that run is still live
    let outcome = try store.fireNow(jobId: job.id, now: dueFirst)

    // then — a distinct outcome (NOT .ineligible, which the handler maps to "not found"); no
    // second run, window unchanged, and the overlap skip is audited
    #expect(outcome == .skippedActiveRun)
    #expect(
      try count(
        queue,
        sql: "SELECT COUNT(*) FROM runs WHERE session_id = ?",
        arguments: [firstFire.sessionId]
      ) == 1
    )
    #expect(try windowStart(queue, sessionId: firstFire.sessionId) == windowBeforeSecond)
    #expect(try auditCount(queue, action: .jobOverlapSkipped) == 1)
    // the skipped /runnow left the fire clock on the first real fire (baseNow), not dueFirst
    #expect(try store.job(id: job.id)?.lastFiredAt == baseNow)
  }
}
