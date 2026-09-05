import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct ScheduleRoutingTests {
  /// Monday 2026-07-06 12:00:00 UTC == 14:00 Europe/Berlin. Injected — no real clocks.
  private static let fixedNow = SchedulingTestClock.mondayNoonBerlin

  private static let weekdayDraft = ScheduleDraft(
    label: "morning digest",
    prompt: "Summarize my unread items",
    schedule: DraftSchedule(kind: .weekdays, time: "07:00", timezone: "Europe/Berlin")
  )

  private struct Harness {
    let router: MessageRouter

    let transport: RecordingTransport
    let dispatcher: FakeTurnRunner
    let parser: FakeDraftParser

    let pending: PendingConfirmationRegistry

    let jobs: ScheduledJobStoreGRDB
    let queue: DatabaseQueue
  }

  private func makeHarness(
    parseResults: [ScheduleDraftParseResult] = [.draft(Self.weekdayDraft)]
  ) throws -> Harness {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try AllowlistStoreGRDB(writer: queue).seedAllowlist(userIds: [42])
    let transport = RecordingTransport()
    let dispatcher = FakeTurnRunner()
    let parser = FakeDraftParser(results: parseResults)
    let pending = PendingConfirmationRegistry()
    let router = Self.makeRouter(
      queue: queue,
      transport: transport,
      dispatcher: dispatcher,
      parser: parser,
      pending: pending
    )
    return Harness(
      router: router,
      transport: transport,
      dispatcher: dispatcher,
      parser: parser,
      pending: pending,
      jobs: ScheduledJobStoreGRDB(writer: queue),
      queue: queue
    )
  }

  /// A standalone factory so the restart test can rebuild the router (fresh ephemeral registry)
  /// over the SAME database — the DB-reopen-as-restart house pattern, registry edition.
  private static func makeRouter(
    queue: DatabaseQueue,
    transport: RecordingTransport,
    dispatcher: FakeTurnRunner,
    parser: FakeDraftParser,
    pending: PendingConfirmationRegistry
  ) -> MessageRouter {
    MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: pending,
      botIdentity: BotIdentity(id: 900, username: "claw_bot"),
      accessControl: AccessControl(
        allowlist: AllowlistStoreGRDB(writer: queue),
        groupChats: []
      ),
      delivery: transport,
      turnRunner: dispatcher,
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: ScheduleSurface(
        parser: parser,
        validator: ScheduleDraftValidator(minIntervalMinutes: 5, defaultTimezone: .gmt),
        calculator: OccurrenceCalculator(),
        jobs: ScheduledJobStoreGRDB(writer: queue),
        commands: ScheduleCommandStoreGRDB(writer: queue)
      ),
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      now: { Self.fixedNow },
      logger: TestLog.silent
    )
  }

  private func jobCount(_ harness: Harness) throws -> Int {
    try harness.jobs.listAll().count
  }

  @Test func scheduleCreateParksAndSendsTheConfirmPrompt() async throws {
    // given
    let harness = try makeHarness()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule every weekday at 7am Berlin")
    )

    // then — verbatim label/prompt, words, tz, and the next 3 LOCAL fire times; nothing armed
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    let prompt = try #require(sent.first?.text)
    #expect(prompt.contains("«morning digest»"))
    #expect(prompt.contains("«Summarize my unread items»"))
    #expect(prompt.contains("every weekday at 07:00"))
    #expect(prompt.contains("Europe/Berlin"))
    #expect(prompt.contains("2026-07-07 07:00"))
    #expect(prompt.contains("2026-07-08 07:00"))
    #expect(prompt.contains("2026-07-09 07:00"))
    #expect(try jobCount(harness) == 0)
    #expect(await harness.parser.ownerTexts == ["every weekday at 7am Berlin"])
    let sessionId = try #require(
      try SessionMessageStoreGRDB(writer: harness.queue).findSession(
        sessionKey: SessionKey.telegramDM(chatId: 42)
      )
    )
    #expect(await harness.pending.pending(sessionId: sessionId) != nil)
  }

  @Test func yesArmsTheExactParkedDraftOnce() async throws {
    // given
    let harness = try makeHarness()
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule every weekday at 7am Berlin")
    )

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "yes"))

    // then — armed from the parked value: owner chat set in code, first fire == the preview's
    #expect(outcome == .processed)
    let jobs = try harness.jobs.listAll()
    #expect(jobs.count == 1)
    let job = try #require(jobs.first)
    #expect(job.label == "morning digest")
    #expect(job.prompt == "Summarize my unread items")
    #expect(job.ownerChatId == 42)
    #expect(job.status == .active)
    #expect(job.timezone == "Europe/Berlin")
    #expect(job.nextOccurrence == SchedulingTestClock.tuesdaySevenBerlin)
    let ack = await harness.transport.sent.last?.text ?? ""
    #expect(ack.contains("Armed schedule \(job.id)"))
    #expect(ack.contains("morning digest"))
    #expect(ack.contains("2026-07-07 07:00"))
  }

  /// A draft confirmed long after its preview must arm the NEXT occurrence from the arm-time
  /// clock, not the stale parked `firstOccurrence` (M1): the validator/parser can never produce
  /// this shape (it anchors recurring drafts at park-now), so the stale draft is parked directly.
  @Test func armRecomputesNextOccurrenceForADraftParkedInThePast() async throws {
    // given — a recurring draft whose parked firstOccurrence (last Sunday) is long past
    let harness = try makeHarness()
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule every weekday at 7am Berlin")
    )
    let sessionId = try #require(
      try SessionMessageStoreGRDB(writer: harness.queue).findSession(
        sessionKey: SessionKey.telegramDM(chatId: 42)
      )
    )
    let rule = Calendar.RecurrenceRule(
      calendar: {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
      }(),
      frequency: .weekly,
      weekdays: [
        .every(.monday), .every(.tuesday), .every(.wednesday), .every(.thursday),
        .every(.friday),
      ],
      hours: [7],
      minutes: [0],
      seconds: [0]
    )
    let stale = ValidatedSchedule(
      label: "morning digest",
      prompt: "Summarize my unread items",
      recurrence: RecurrenceEnvelope(schemaVersion: 1, rule: rule),
      timezone: "Europe/Berlin",
      firstOccurrence: Self.fixedNow.addingTimeInterval(-86_400)
    )
    await harness.pending.park(.scheduleArm(stale), sessionId: sessionId)

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "yes"))

    // then — armed forward from now (Tue 07:00 Berlin), never the stale Sunday value
    #expect(outcome == .processed)
    let jobs = try harness.jobs.listAll()
    #expect(jobs.count == 1)
    let job = try #require(jobs.first)
    #expect(job.nextOccurrence == SchedulingTestClock.tuesdaySevenBerlin)
  }

  /// The confirm preview anchors on the parked draft's `firstOccurrence`, so arming must too —
  /// anchoring on arm-time `now` instead would re-phase the whole everyNMinutes chain off what
  /// the owner just confirmed (preamble deviation #1: phase-continuous from preview to fire).
  @Test func armPreservesEveryNMinutesPhaseFromThePreview() async throws {
    // given — a 30-minute draft parked with a past, off-now-phase firstOccurrence (:05/:35)
    let harness = try makeHarness()
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule every weekday at 7am Berlin")
    )
    let sessionId = try #require(
      try SessionMessageStoreGRDB(writer: harness.queue).findSession(
        sessionKey: SessionKey.telegramDM(chatId: 42)
      )
    )
    let calendar: Calendar = try {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
      return calendar
    }()
    let rule = Calendar.RecurrenceRule(
      calendar: calendar,
      frequency: .minutely,
      interval: 30,
      seconds: [0]
    )
    let stale = ValidatedSchedule(
      label: "heartbeat",
      prompt: "Post the heartbeat",
      recurrence: RecurrenceEnvelope(schemaVersion: 1, rule: rule),
      timezone: "Europe/Berlin",
      firstOccurrence: Date(timeIntervalSince1970: 1_783_337_700)
    )
    await harness.pending.park(.scheduleArm(stale), sessionId: sessionId)

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "yes"))

    // then — next :05/:35-phase fire after now (12:05), not the re-phased :00/:30 (12:30)
    #expect(outcome == .processed)
    let jobs = try harness.jobs.listAll()
    #expect(jobs.count == 1)
    let job = try #require(jobs.first)
    #expect(job.nextOccurrence == Date(timeIntervalSince1970: 1_783_339_500))
  }

  /// A parked one-shot confirmed after its only instant already passed cannot be salvaged: arming
  /// it would silently misfire to COMPLETED with no run, so it is rejected instead (M1).
  @Test func armOfAOneShotWhoseInstantPassedIsRejected() async throws {
    // given — a one-shot draft whose parked firstOccurrence is an hour in the past
    let harness = try makeHarness()
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule every weekday at 7am Berlin")
    )
    let sessionId = try #require(
      try SessionMessageStoreGRDB(writer: harness.queue).findSession(
        sessionKey: SessionKey.telegramDM(chatId: 42)
      )
    )
    let stale = ValidatedSchedule(
      label: "send report",
      prompt: "Send the report reminder",
      recurrence: nil,
      timezone: "Europe/Berlin",
      firstOccurrence: Self.fixedNow.addingTimeInterval(-3_600)
    )
    await harness.pending.park(.scheduleArm(stale), sessionId: sessionId)

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "yes"))

    // then — nothing armed, owner told to reschedule, slot cleared
    #expect(outcome == .processed)
    #expect(try jobCount(harness) == 0)
    #expect(await harness.transport.sent.last?.text == ScheduleReplies.armExpired)
    #expect(await harness.pending.pending(sessionId: sessionId) == nil)
  }

  @Test func replayedYesIsIdempotent() async throws {
    // given
    let harness = try makeHarness()
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule every weekday at 7am Berlin")
    )
    await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "yes"))

    // when — Telegram redelivers the same "yes" update
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "yes"))

    // then — the update_id claim already lost; still exactly one job
    #expect(outcome == .skipped)
    #expect(try jobCount(harness) == 1)
  }

  @Test func noCancelsAndNothingIsArmed() async throws {
    // given
    let harness = try makeHarness()
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule every weekday at 7am Berlin")
    )

    // when
    await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "no"))

    // then — cancelled ack, no job; a LATER "yes" is a plain turn, not an arm
    #expect(await harness.transport.sent.last?.text == MemoryReplies.cancelled)
    #expect(try jobCount(harness) == 0)
    await harness.router.handle(rawUpdate: textUpdate(id: 3, from: 42, text: "yes"))
    await harness.dispatcher.waitForCalls(atLeast: 1)
    #expect(try jobCount(harness) == 0)
  }

  @Test func otherTextClearsTheDraftAndFallsThroughToATurn() async throws {
    // given
    let harness = try makeHarness()
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule every weekday at 7am Berlin")
    )

    // when
    await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "what's the weather?")
    )
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then — the text became an ordinary turn and the slot is empty
    #expect(await harness.dispatcher.calls.count == 1)
    #expect(try jobCount(harness) == 0)
    let sessionId = try #require(
      try SessionMessageStoreGRDB(writer: harness.queue).findSession(
        sessionKey: SessionKey.telegramDM(chatId: 42)
      )
    )
    #expect(await harness.pending.pending(sessionId: sessionId) == nil)
  }

  @Test func restartDropsTheParkedDraft() async throws {
    // given — a draft parked, then the daemon restarts (fresh ephemeral registry, same DB; D10)
    let harness = try makeHarness()
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule every weekday at 7am Berlin")
    )
    let rebooted = Self.makeRouter(
      queue: harness.queue,
      transport: harness.transport,
      dispatcher: harness.dispatcher,
      parser: harness.parser,
      pending: PendingConfirmationRegistry()
    )

    // when
    await rebooted.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "yes"))
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then — "yes" became a plain turn; nothing armed
    #expect(try jobCount(harness) == 0)
  }

  @Test func providerFailureRepliesDegradationAndArmsNothing() async throws {
    // given
    let harness = try makeHarness(parseResults: [.providerUnavailable])

    // when
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule every weekday at 7am")
    )

    // then — the DEG-01 reply, nothing parked, nothing armed
    #expect(await harness.transport.sent.last?.text == Degradation.providerUnavailable)
    #expect(try jobCount(harness) == 0)
    let sessionId = try #require(
      try SessionMessageStoreGRDB(writer: harness.queue).findSession(
        sessionKey: SessionKey.telegramDM(chatId: 42)
      )
    )
    #expect(await harness.pending.pending(sessionId: sessionId) == nil)
  }

  @Test func unparseableTextGetsTheExampleRephrase() async throws {
    // given
    let harness = try makeHarness(parseResults: [.unparseable])

    // when
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule gibberish")
    )

    // then
    #expect(await harness.transport.sent.last?.text == ScheduleReplies.parseFailed)
    #expect(try jobCount(harness) == 0)
  }

  @Test func validationFailureRepliesThePlainLanguageProblem() async throws {
    // given — the model proposed a below-floor interval; deterministic code rejects it
    let fastDraft = ScheduleDraft(
      label: "spammer",
      prompt: "poll",
      schedule: DraftSchedule(kind: .everyNMinutes, intervalMinutes: 1)
    )
    let harness = try makeHarness(parseResults: [.draft(fastDraft)])

    // when
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule every minute poll")
    )

    // then — the problem's own reply (with example), nothing parked or armed
    let reply = await harness.transport.sent.last?.text ?? ""
    #expect(
      reply == ScheduleDraftProblem.intervalTooSmall(minutes: 1, floorMinutes: 5).ownerReply
    )
    #expect(try jobCount(harness) == 0)
  }

  @Test func listShowsEmptyHintThenArmedJobs() async throws {
    // given
    let harness = try makeHarness()

    // when — list before anything exists
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "/schedule list"))

    // then
    #expect(await harness.transport.sent.last?.text == ScheduleReplies.emptyList)

    // when — arm one, list again
    await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "/schedule every weekday at 7am Berlin")
    )
    await harness.router.handle(rawUpdate: textUpdate(id: 3, from: 42, text: "yes"))
    await harness.router.handle(rawUpdate: textUpdate(id: 4, from: 42, text: "/schedule list"))

    // then — id · label · status · words · tz · next fire, all from one calculator
    let line = await harness.transport.sent.last?.text ?? ""
    #expect(line.contains("morning digest"))
    #expect(line.contains(ScheduledJobStatus.active.rawValue))
    #expect(line.contains("every weekday at 07:00"))
    #expect(line.contains("Europe/Berlin"))
    #expect(line.contains("next 2026-07-07 07:00"))
  }

  @Test func strangersNeverReachTheScheduleSurface() async throws {
    // given
    let harness = try makeHarness()

    // when — a non-allowlisted sender tries to create and list
    await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 7, text: "/schedule every weekday at 7am")
    )
    await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "/schedule list"))

    // then — private-bot replies only; the parser was never invoked; nothing exists
    let sent = await harness.transport.sent
    #expect(sent.count == 2)
    #expect(sent.allSatisfy { reply in reply.text == MessageRouter.privateBotText })
    #expect(await harness.parser.ownerTexts.isEmpty)
    #expect(try jobCount(harness) == 0)
  }
}
