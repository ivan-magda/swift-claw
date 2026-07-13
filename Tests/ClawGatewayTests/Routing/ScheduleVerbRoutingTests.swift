import ClawAgent
import ClawCore
import ClawData
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct ScheduleVerbRoutingTests {
  /// Monday 2026-07-06 12:00:00 UTC == 14:00 Europe/Berlin.
  private static let fixedNow = Date(timeIntervalSince1970: 1_783_339_200)
  /// Tuesday 2026-07-07 07:00 Europe/Berlin == 05:00 UTC — the next daily-07:00 fire.
  private static let nextDailyFire = Date(timeIntervalSince1970: 1_783_400_400)

  private struct Harness {
    let router: MessageRouter

    let transport: RecordingTransport
    let dispatcher: FakeTurnRunner

    let jobs: ScheduledJobStoreGRDB
    let queue: DatabaseQueue
  }

  private func makeHarness() throws -> Harness {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try AllowlistStoreGRDB(writer: queue).seedAllowlist(userIds: [42])
    let transport = RecordingTransport()
    let dispatcher = FakeTurnRunner()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: AllowlistStoreGRDB(writer: queue)),
      delivery: transport,
      turnRunner: dispatcher,
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      now: { Self.fixedNow },
      logger: TestLog.silent
    )
    return Harness(
      router: router,
      transport: transport,
      dispatcher: dispatcher,
      jobs: ScheduledJobStoreGRDB(writer: queue),
      queue: queue
    )
  }

  /// Seeds one ACTIVE daily-07:00-Berlin job directly through the plain-insert store method
  /// (the arm flow is Task 16's suite; verbs only need an existing row).
  @discardableResult
  private func seedDailyJob(
    _ harness: Harness,
    nextOccurrence: Date = ScheduleVerbRoutingTests.nextDailyFire
  ) throws -> ScheduledJob {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
    let rule = Calendar.RecurrenceRule(
      calendar: calendar,
      frequency: .daily,
      hours: [7],
      minutes: [0],
      seconds: [0]
    )
    return try harness.jobs.create(
      NewScheduledJob(
        ownerChatId: 42,
        label: "morning digest",
        prompt: "Summarize my unread items",
        recurrence: RecurrenceEnvelope(schemaVersion: 1, rule: rule),
        timezone: "Europe/Berlin",
        nextOccurrence: nextOccurrence
      ),
      now: Self.fixedNow
    )
  }

  @discardableResult
  private func seedOneShot(
    _ harness: Harness,
    nextOccurrence: Date
  ) throws -> ScheduledJob {
    try harness.jobs.create(
      NewScheduledJob(
        ownerChatId: 42,
        label: "one reminder",
        prompt: "Send the report reminder",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: nextOccurrence
      ),
      now: Self.fixedNow
    )
  }

  @Test func pauseFlipsStatusAndAuditsInTheStoreTransaction() async throws {
    // given
    let harness = try makeHarness()
    let seeded = try seedDailyJob(harness)

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/pause \(seeded.id)")
    )

    // then
    #expect(outcome == .processed)
    let job = try #require(try harness.jobs.job(id: seeded.id))
    #expect(job.status == .paused)
    let reply = await harness.transport.sent.last?.text ?? ""
    #expect(reply.contains("Paused schedule \(seeded.id)"))
    // the jobPaused audit rode the store's own transaction (Phase 1); prove the integration
    let auditCount = try await harness.queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM audit_events WHERE action = '\(AuditAction.jobPaused.rawValue)'"
      ) ?? -1
    }
    #expect(auditCount == 1)
  }

  @Test func pauseIsIdempotent() async throws {
    // given
    let harness = try makeHarness()
    let seeded = try seedDailyJob(harness)
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "/pause \(seeded.id)"))

    // when — a second /pause with a NEW update id (not a redelivery)
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "/pause \(seeded.id)")
    )

    // then — still paused, still a friendly ack, no error
    #expect(outcome == .processed)
    let job = try #require(try harness.jobs.job(id: seeded.id))
    #expect(job.status == .paused)
  }

  @Test func resumeRecomputesNextFromNowSkippingMissedOccurrences() async throws {
    // given — the job was due YESTERDAY-morning while paused; resume must NOT catch that up
    let harness = try makeHarness()
    let pastDue = Date(timeIntervalSince1970: 1_783_314_000)  // Mon 2026-07-06 05:00 UTC
    let seeded = try seedDailyJob(harness, nextOccurrence: pastDue)
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "/pause \(seeded.id)"))

    // when
    await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "/resume \(seeded.id)")
    )

    // then — ACTIVE again, next = the calculator's next-after-now (Tue 07:00 Berlin), not pastDue
    let job = try #require(try harness.jobs.job(id: seeded.id))
    #expect(job.status == .active)
    #expect(job.nextOccurrence == Self.nextDailyFire)
    let reply = await harness.transport.sent.last?.text ?? ""
    #expect(reply.contains("Resumed schedule \(seeded.id)"))
    #expect(reply.contains("2026-07-07 07:00"))
  }

  @Test func resumeOfAOneShotWhoseInstantPassedHasNothingLeftToFire() async throws {
    // given — a one-shot whose moment passed while paused: skipped, never caught up (§5.4)
    let harness = try makeHarness()
    let pastInstant = Date(timeIntervalSince1970: 1_783_314_000)
    let seeded = try seedOneShot(harness, nextOccurrence: pastInstant)
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "/pause \(seeded.id)"))

    // when
    await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "/resume \(seeded.id)")
    )

    // then — no future fire is stored; the ticker's `next_occurrence <= now` scan never sees it
    let job = try #require(try harness.jobs.job(id: seeded.id))
    #expect(job.nextOccurrence == nil)
    let reply = await harness.transport.sent.last?.text ?? ""
    #expect(reply.contains("Nothing left to fire"))
  }

  @Test func runNowFiresThroughTheLaneWithoutMovingTheSchedule() async throws {
    // given
    let harness = try makeHarness()
    let seeded = try seedDailyJob(harness)

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/runnow \(seeded.id)")
    )
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then — a real turn dispatched to the owner DM; the schedule untouched (§5.4)
    #expect(outcome == .processed)
    let calls = await harness.dispatcher.calls
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    #expect(call.chatId == 42)
    let job = try #require(try harness.jobs.job(id: seeded.id))
    #expect(job.nextOccurrence == Self.nextDailyFire)
    let reply = await harness.transport.sent.last?.text ?? ""
    #expect(reply.contains("Running schedule \(seeded.id) now"))
  }

  @Test func runNowWorksOnAPausedJobWithoutUnmutingIt() async throws {
    // given — the deliberate test-without-unmute semantic (spec §5.4 / §20)
    let harness = try makeHarness()
    let seeded = try seedDailyJob(harness)
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "/pause \(seeded.id)"))

    // when
    await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "/runnow \(seeded.id)")
    )
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then — fired once, still PAUSED
    #expect(await harness.dispatcher.calls.count == 1)
    let job = try #require(try harness.jobs.job(id: seeded.id))
    #expect(job.status == .paused)
  }

  @Test func redeliveredRunNowFiresOnlyOnce() async throws {
    // given
    let harness = try makeHarness()
    let seeded = try seedDailyJob(harness)
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/runnow \(seeded.id)")
    )
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // when — the SAME update id again (Telegram redelivery; §5.4's idempotency claim)
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/runnow \(seeded.id)")
    )

    // then
    #expect(outcome == .skipped)
    #expect(await harness.dispatcher.calls.count == 1)
  }

  @Test func cancelRetainsTheRowAndStopsFutureFires() async throws {
    // given
    let harness = try makeHarness()
    let seeded = try seedDailyJob(harness)

    // when
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/cancel \(seeded.id)")
    )

    // then — terminal, next NULL, row retained for audit (spec §5.4)
    let job = try #require(try harness.jobs.job(id: seeded.id))
    #expect(job.status == .cancelled)
    #expect(job.nextOccurrence == nil)
    let reply = await harness.transport.sent.last?.text ?? ""
    #expect(reply.contains("Cancelled schedule \(seeded.id)"))
  }

  @Test func unknownIdGetsAHelpfulErrorWithTheListHint() async throws {
    // given
    let harness = try makeHarness()

    // when
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "/pause 99"))

    // then
    #expect(await harness.transport.sent.last?.text == ScheduleReplies.notFound(id: 99))
  }

  @Test func missingIdGetsUsageWithTheListHint() async throws {
    // given
    let harness = try makeHarness()

    // when — bare /cancel (spec §9: usage + list hint) and a garbage /pause argument
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "/cancel"))
    await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "/pause abc"))

    // then
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [ScheduleReplies.cancelUsage, ScheduleReplies.pauseUsage])
  }

  @Test func strangersNeverReachTheVerbs() async throws {
    // given
    let harness = try makeHarness()
    let seeded = try seedDailyJob(harness)

    // when
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "/pause \(seeded.id)"))
    await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "/runnow \(seeded.id)"))

    // then — private-bot replies; the job is untouched and nothing ran
    let sent = await harness.transport.sent
    #expect(sent.allSatisfy { reply in reply.text == MessageRouter.privateBotText })
    let job = try #require(try harness.jobs.job(id: seeded.id))
    #expect(job.status == .active)
    #expect(await harness.dispatcher.calls.isEmpty)
  }
}
