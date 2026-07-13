import ClawAgent
import ClawCore
import ClawTestSupport
import ClawWorkspace
import Foundation
import Logging
import Testing

@testable import ClawGateway

/// A scripted `ScheduledJobStore`: seeded jobs, recorded claim/skip/tick calls, one canned claim
/// result. A lock-guarded class, not an actor, for the same reason as `RecordingUsageStore`
/// (the protocol is synchronous).
final class ScriptedJobStore: ScheduledJobStore, @unchecked Sendable {
  struct ClaimCall: Equatable {
    let jobId: Int64
    let due: Date
    let fireAt: Date
    let nextOccurrence: Date?
  }

  struct SkipCall: Equatable {
    let jobId: Int64
    let due: Date
    let nextOccurrence: Date?
    let skippedCount: Int
  }

  struct HeartbeatCall: Equatable {
    let prompt: String
    let ownerChatId: Int64
    let day: String
  }

  private let lock = NSLock()
  private var seededJobs: [ScheduledJob]
  private var recordedClaims: [ClaimCall] = []
  private var recordedSkips: [SkipCall] = []
  private var recordedTicks: [Date] = []
  private let claimResult: ClaimedFire?
  private let cannedState: SchedulerState
  private let heartbeatResult: ClaimedFire?
  private var recordedHeartbeats: [HeartbeatCall] = []

  init(
    jobs: [ScheduledJob],
    claimResult: ClaimedFire?,
    state: SchedulerState = SchedulerState(
      lastTickAt: nil,
      lastMisfireAt: nil,
      lastMisfireSkippedCount: 0,
      lastHeartbeatAt: nil,
      heartbeatCountDay: nil,
      heartbeatCount: 0
    ),
    heartbeatResult: ClaimedFire? = nil
  ) {
    seededJobs = jobs
    self.claimResult = claimResult
    cannedState = state
    self.heartbeatResult = heartbeatResult
  }

  var claims: [ClaimCall] {
    lock.lock()
    defer { lock.unlock() }
    return recordedClaims
  }

  var skips: [SkipCall] {
    lock.lock()
    defer { lock.unlock() }
    return recordedSkips
  }

  var ticks: [Date] {
    lock.lock()
    defer { lock.unlock() }
    return recordedTicks
  }

  var heartbeatFires: [HeartbeatCall] {
    lock.lock()
    defer { lock.unlock() }
    return recordedHeartbeats
  }

  func dueJobs(now: Date) throws(StoreError) -> [ScheduledJob] {
    lock.lock()
    defer { lock.unlock() }
    // Mirrors the store contract: status='ACTIVE' AND next_occurrence <= now.
    return seededJobs.filter { job in
      job.status == .active && job.nextOccurrence.map { occurrence in occurrence <= now } == true
    }
  }

  func claimAndFire(
    jobId: Int64,
    due: Date,
    fireAt: Date,
    nextOccurrence: Date?,
    now: Date
  ) throws(StoreError) -> ClaimedFire? {
    lock.lock()
    defer { lock.unlock() }
    recordedClaims.append(
      ClaimCall(jobId: jobId, due: due, fireAt: fireAt, nextOccurrence: nextOccurrence)
    )
    return claimResult
  }

  func skipMisfire(
    jobId: Int64,
    due: Date,
    nextOccurrence: Date?,
    skippedCount: Int,
    now: Date
  ) throws(StoreError) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    recordedSkips.append(
      SkipCall(jobId: jobId, due: due, nextOccurrence: nextOccurrence, skippedCount: skippedCount)
    )
    return true
  }

  func recordTick(at tickTime: Date) throws(StoreError) {
    lock.lock()
    defer { lock.unlock() }
    recordedTicks.append(tickTime)
  }

  // Unused by the ticker — loud if the service ever starts calling them.
  func create(_ job: NewScheduledJob, now: Date) throws(StoreError) -> ScheduledJob {
    throw StoreError.unexpected("unused by SchedulerService")
  }

  func job(id: Int64) throws(StoreError) -> ScheduledJob? { nil }

  func listAll() throws(StoreError) -> [ScheduledJob] { [] }

  func fireNow(jobId: Int64, now: Date) throws(StoreError) -> ClaimedFire? {
    throw StoreError.unexpected("unused by SchedulerService")
  }

  func pause(id: Int64, now: Date) throws(StoreError) -> ScheduledJob? {
    throw StoreError.unexpected("unused by SchedulerService")
  }

  func resume(id: Int64, nextOccurrence: Date?, now: Date) throws(StoreError) -> ScheduledJob? {
    throw StoreError.unexpected("unused by SchedulerService")
  }

  func cancel(id: Int64, now: Date) throws(StoreError) -> ScheduledJob? {
    throw StoreError.unexpected("unused by SchedulerService")
  }

  func schedulerState() throws(StoreError) -> SchedulerState {
    lock.lock()
    defer { lock.unlock() }
    return cannedState
  }

  func fireHeartbeat(
    prompt: String,
    ownerChatId: Int64,
    now: Date,
    day: String
  ) throws(StoreError) -> ClaimedFire {
    lock.lock()
    defer { lock.unlock() }
    recordedHeartbeats.append(HeartbeatCall(prompt: prompt, ownerChatId: ownerChatId, day: day))
    guard let heartbeatResult else {
      throw StoreError.unexpected("fireHeartbeat called without a scripted result")
    }
    return heartbeatResult
  }
}

/// Records the durations the run() loop sleeps; throwing ends the loop like a cancellation.
private final class SleepRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedDurations: [Duration] = []

  var durations: [Duration] {
    lock.lock()
    defer { lock.unlock() }
    return recordedDurations
  }

  func append(_ duration: Duration) {
    lock.lock()
    defer { lock.unlock() }
    recordedDurations.append(duration)
  }
}

@Suite struct SchedulerServiceTests {
  /// The occurrence phase anchor; the every-5-min rule recurs at anchor + k·300 s exactly.
  private let anchor = Date(timeIntervalSince1970: 1_750_000_000)

  private func everyFiveMinutesRule() -> Calendar.RecurrenceRule {
    SchedulingRuleFixtures.everyNMinutes(5, zone: TimeZone(identifier: "Europe/Berlin") ?? .gmt)
  }

  private func makeJob(
    id: Int64 = 7,
    recurrence: RecurrenceEnvelope?,
    nextOccurrence: Date?,
    status: ScheduledJobStatus = .active
  ) -> ScheduledJob {
    ScheduledJob(
      id: id,
      ownerChatId: 42,
      label: "digest",
      prompt: "Summarize my unread items",
      recurrence: recurrence,
      timezone: "Europe/Berlin",
      nextOccurrence: nextOccurrence,
      lastFiredAt: nil,
      status: status,
      sessionId: nil,
      createdTs: anchor,
      updatedTs: anchor
    )
  }

  private struct Fixture {
    let service: SchedulerService
    let store: ScriptedJobStore
    let runner: FakeTurnRunner
  }

  private func makeFixture(
    jobs: [ScheduledJob],
    claimResult: ClaimedFire? = ClaimedFire(
      runId: 900,
      sessionId: 500,
      triggerMessageId: 300,
      ownerChatId: 42
    ),
    heartbeat: HeartbeatSettings = .disabled,
    now: Date
  ) -> Fixture {
    let store = ScriptedJobStore(jobs: jobs, claimResult: claimResult)
    let runner = FakeTurnRunner()
    let service = SchedulerService(
      jobs: store,
      lanes: SessionLaneRegistry(),
      turns: runner,
      calculator: OccurrenceCalculator(),
      catchUpMaxAge: .seconds(1800),
      heartbeat: heartbeat,
      workspace: EmptyWorkspace(),
      audit: RecordingAuditLog(),
      now: { now },
      clock: ScriptedClock { _ in },
      logger: TestLog.silent
    )
    return Fixture(service: service, store: store, runner: runner)
  }

  @Test func onTimeDueJobFiresAtItsOccurrenceAndRunsOnTheLane() async throws {
    // given — due 30 s ago: lateness ≤ the 60 s grain ⇒ fire at the stored occurrence
    let due = anchor.addingTimeInterval(600)
    let now = due.addingTimeInterval(30)
    let job = makeJob(
      recurrence: RecurrenceEnvelope(schemaVersion: 1, rule: everyFiveMinutesRule()),
      nextOccurrence: due
    )
    let fixture = makeFixture(jobs: [job], now: now)

    // when
    await fixture.service.tick()

    // then — CAS on due, fireAt == due, next advanced strictly past now (T0+900)
    #expect(fixture.store.ticks == [now])
    #expect(
      fixture.store.claims == [
        ScriptedJobStore.ClaimCall(
          jobId: 7,
          due: due,
          fireAt: due,
          nextOccurrence: anchor.addingTimeInterval(900)
        )
      ]
    )
    #expect(fixture.store.skips.isEmpty)

    // and the claimed fire ran through the session lane with the ClaimedFire identity
    await fixture.runner.waitForCalls(atLeast: 1)
    let call = try #require(await fixture.runner.calls.first)
    #expect(
      call
        == FakeTurnRunner.Call(
          runId: 900,
          sessionId: 500,
          chatId: 42,
          triggerMessageId: 300
        )
    )
  }

  @Test func missedOccurrencesInsideTheWindowCoalesceToOneFireAtTheLatest() async throws {
    // given — due at T0+300; now T0+1530: five occurrences missed (300…1500), all < 30 min old
    let due = anchor.addingTimeInterval(300)
    let now = anchor.addingTimeInterval(1530)
    let job = makeJob(
      recurrence: RecurrenceEnvelope(schemaVersion: 1, rule: everyFiveMinutesRule()),
      nextOccurrence: due
    )
    let fixture = makeFixture(jobs: [job], now: now)

    // when
    await fixture.service.tick()

    // then — exactly ONE claim: CAS still on the stored due, T_fire = the latest missed (§5.2/§5.3)
    #expect(
      fixture.store.claims == [
        ScriptedJobStore.ClaimCall(
          jobId: 7,
          due: due,
          fireAt: anchor.addingTimeInterval(1500),
          nextOccurrence: anchor.addingTimeInterval(1800)
        )
      ]
    )
    #expect(fixture.store.skips.isEmpty)
  }

  @Test func occurrencesOlderThanTheCatchUpWindowAreSkippedWithNoRun() async throws {
    // given — due at T0+300; now T0+2100: lateness 1800 s == catchUpMaxAge ⇒ skip (≥ boundary)
    let due = anchor.addingTimeInterval(300)
    let now = anchor.addingTimeInterval(2100)
    let job = makeJob(
      recurrence: RecurrenceEnvelope(schemaVersion: 1, rule: everyFiveMinutesRule()),
      nextOccurrence: due
    )
    let fixture = makeFixture(jobs: [job], now: now)

    // when
    await fixture.service.tick()

    // then — no run; next advanced past now; the missed count (300…2100 = 7) recorded
    #expect(fixture.store.claims.isEmpty)
    #expect(
      fixture.store.skips == [
        ScriptedJobStore.SkipCall(
          jobId: 7,
          due: due,
          nextOccurrence: anchor.addingTimeInterval(2400),
          skippedCount: 7
        )
      ]
    )
    #expect(await fixture.runner.calls.isEmpty)
  }

  @Test func pausedJobsNeverFire() async throws {
    // given — a PAUSED job whose occurrence is long past; the scan predicate excludes it
    let due = anchor.addingTimeInterval(300)
    let now = anchor.addingTimeInterval(600)
    let job = makeJob(
      recurrence: RecurrenceEnvelope(schemaVersion: 1, rule: everyFiveMinutesRule()),
      nextOccurrence: due,
      status: .paused
    )
    let fixture = makeFixture(jobs: [job], now: now)

    // when
    await fixture.service.tick()

    // then — the tick still records; nothing fires or skips
    #expect(fixture.store.ticks == [now])
    #expect(fixture.store.claims.isEmpty)
    #expect(fixture.store.skips.isEmpty)
  }

  @Test func oneShotJobFiresWithNilNextOccurrence() async throws {
    // given — recurrence nil ⇔ one-shot; the store completes it on nil (§5.2)
    let due = anchor.addingTimeInterval(600)
    let now = due.addingTimeInterval(30)
    let fixture = makeFixture(jobs: [makeJob(recurrence: nil, nextOccurrence: due)], now: now)

    // when
    await fixture.service.tick()

    // then
    #expect(
      fixture.store.claims == [
        ScriptedJobStore.ClaimCall(jobId: 7, due: due, fireAt: due, nextOccurrence: nil)
      ]
    )
  }

  @Test func lostClaimEnqueuesNothing() async throws {
    // given — the CAS matched no row (claimed elsewhere / job mutated): claimAndFire → nil
    let due = anchor.addingTimeInterval(600)
    let now = due.addingTimeInterval(30)
    let job = makeJob(
      recurrence: RecurrenceEnvelope(schemaVersion: 1, rule: everyFiveMinutesRule()),
      nextOccurrence: due
    )
    let fixture = makeFixture(jobs: [job], claimResult: nil, now: now)

    // when
    await fixture.service.tick()

    // then — the claim was attempted, but no turn was dispatched
    #expect(fixture.store.claims.count == 1)
    #expect(await fixture.runner.calls.isEmpty)
  }

  @Test func runTicksImmediatelyThenSleepsTheTickInterval() async throws {
    // given — a sleep that records its duration and ends the loop like a cancellation
    let recorder = SleepRecorder()
    let store = ScriptedJobStore(jobs: [], claimResult: nil)
    let service = SchedulerService(
      jobs: store,
      lanes: SessionLaneRegistry(),
      turns: FakeTurnRunner(),
      calculator: OccurrenceCalculator(),
      catchUpMaxAge: .seconds(1800),
      heartbeat: .disabled,
      workspace: EmptyWorkspace(),
      audit: RecordingAuditLog(),
      now: { Date(timeIntervalSince1970: 1_750_000_000) },
      clock: ScriptedClock { duration in
        recorder.append(duration)
        throw CancellationError()
      },
      logger: TestLog.silent
    )

    // when — restart recovery: the first tick happens BEFORE the first sleep
    try await service.run()

    // then
    #expect(store.ticks.count == 1)
    #expect(recorder.durations == [SchedulerService.tickInterval])
  }
}
