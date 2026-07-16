import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct ScheduleInteractionTests {
  private static let fixedNow = SchedulingTestClock.mondayNoonBerlin

  private static let morningDraft = ScheduleDraft(
    label: "morning digest",
    prompt: "Summarize my unread items",
    schedule: DraftSchedule(kind: .weekdays, time: "07:00", timezone: "Europe/Berlin")
  )

  private static let eveningDraft = ScheduleDraft(
    label: "evening digest",
    prompt: "Summarize the day",
    schedule: DraftSchedule(kind: .daily, time: "19:00", timezone: "Europe/Berlin")
  )

  private struct Harness {
    let router: MessageRouter
    let transport: RecordingTransport

    let dispatcher: FakeTurnRunner

    let pending: PendingConfirmationRegistry

    let jobs: ScheduledJobStoreGRDB
    let sessions: SessionMessageStoreGRDB
    let queue: DatabaseQueue
  }

  private func makeHarness(
    parseResults: [ScheduleDraftParseResult] = [.draft(Self.morningDraft)]
  ) throws -> Harness {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try AllowlistStoreGRDB(writer: queue).seedAllowlist(userIds: [42])
    let transport = RecordingTransport()
    let dispatcher = FakeTurnRunner()
    let pending = PendingConfirmationRegistry()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: pending,
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: AllowlistStoreGRDB(writer: queue)),
      delivery: transport,
      turnRunner: dispatcher,
      lanes: SessionLaneRegistry(),
      schedule: ScheduleSurface(
        parser: FakeDraftParser(results: parseResults),
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
    return Harness(
      router: router,
      transport: transport,
      dispatcher: dispatcher,
      pending: pending,
      jobs: ScheduledJobStoreGRDB(writer: queue),
      sessions: SessionMessageStoreGRDB(writer: queue),
      queue: queue
    )
  }

  private func ownerSessionId(_ harness: Harness) throws -> Int64 {
    try #require(
      try harness.sessions.findSession(sessionKey: SessionKey.telegramDM(chatId: 42))
    )
  }

  private func parkDraft(_ harness: Harness, updateId: Int64 = 1) async {
    await harness.router.handle(
      rawUpdate: textUpdate(id: updateId, from: 42, text: "/schedule every weekday at 7am")
    )
  }

  @Test func slashCommandsBypassTheParkedConfirmation() async throws {
    // given — a draft is parked
    let harness = try makeHarness()
    await parkDraft(harness)
    let sessionId = try ownerSessionId(harness)

    // when — a slash command arrives while the confirmation is pending
    await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "/schedule list"))

    // then — the command ran (list reply) AND the parked entry survived; "yes" still arms
    #expect(await harness.transport.sent.last?.text == ScheduleReplies.emptyList)
    #expect(await harness.pending.pending(sessionId: sessionId) != nil)
    await harness.router.handle(rawUpdate: textUpdate(id: 3, from: 42, text: "yes"))
    #expect(try harness.jobs.listAll().count == 1)
  }

  @Test func cancelCommandCancelsAJobNotTheParkedDraft() async throws {
    // given — a seeded job AND a parked draft for the same session
    let harness = try makeHarness()
    let seeded = try harness.jobs.create(
      NewScheduledJob(
        ownerChatId: 42,
        label: "one reminder",
        prompt: "Send the report reminder",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: Date(timeIntervalSince1970: 1_783_486_800)
      ),
      now: Self.fixedNow
    )
    await parkDraft(harness)
    let sessionId = try ownerSessionId(harness)

    // when — /cancel-the-COMMAND targets the job
    await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "/cancel \(seeded.id)")
    )

    // then — job cancelled, draft still parked, and "yes" still arms it
    let job = try #require(try harness.jobs.job(id: seeded.id))
    #expect(job.status == .cancelled)
    #expect(await harness.pending.pending(sessionId: sessionId) != nil)
    await harness.router.handle(rawUpdate: textUpdate(id: 3, from: 42, text: "yes"))
    #expect(try harness.jobs.listAll().count == 2)
  }

  @Test func cancelWordRejectsTheParkedDraft() async throws {
    // given
    let harness = try makeHarness()
    await parkDraft(harness)
    let sessionId = try ownerSessionId(harness)

    // when — the bare WORD keeps its confirmation-rejection meaning (spec §9)
    await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "cancel"))

    // then
    #expect(await harness.transport.sent.last?.text == MemoryReplies.cancelled)
    #expect(await harness.pending.pending(sessionId: sessionId) == nil)
    #expect(try harness.jobs.listAll().isEmpty)
  }

  @Test func secondScheduleDisplacesTheParkedDraft() async throws {
    // given — draft A parked, then a second /schedule parses to draft B (single slot, §9)
    let harness = try makeHarness(
      parseResults: [.draft(Self.morningDraft), .draft(Self.eveningDraft)]
    )
    await parkDraft(harness, updateId: 1)

    // when
    await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "/schedule every day at 7pm")
    )
    await harness.router.handle(rawUpdate: textUpdate(id: 3, from: 42, text: "yes"))

    // then — only the SECOND draft armed; the displaced intent can never be armed
    let jobs = try harness.jobs.listAll()
    #expect(jobs.count == 1)
    #expect(jobs.first?.label == "evening digest")
  }

  @Test func newClearsTheParkedDraft() async throws {
    // given
    let harness = try makeHarness()
    await parkDraft(harness)

    // when — /new is the one command that clears the slot (existing handleNew behavior)
    await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "/new"))
    await harness.router.handle(rawUpdate: textUpdate(id: 3, from: 42, text: "yes"))
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then — "yes" became a plain turn; nothing armed
    #expect(try harness.jobs.listAll().isEmpty)
  }

  @Test func authenticationParseFailureGivesTheExactLoginCopyAndArmsNothing() async throws {
    // given — the parse fails because the credential is gone
    let harness = try makeHarness(parseResults: [.authenticationRequired])

    // when
    await parkDraft(harness)

    // then — the schedule surface hands the owner the same pinned login sentence a turn does
    #expect(await harness.transport.sent.last?.text == ScheduleReplies.authenticationRequired)
    #expect(await harness.transport.sent.last?.text == Degradation.authenticationRequired)
    #expect(try harness.jobs.listAll().isEmpty)
  }

  @Test func quotaParseFailureSaysRetryNotLogin() async throws {
    // given
    let harness = try makeHarness(parseResults: [.quotaLimited(retryAfterSeconds: 30)])

    // when
    await parkDraft(harness)

    // then — the quota reply names the retry, never the login command
    let reply = try #require(await harness.transport.sent.last?.text)
    #expect(reply == ScheduleReplies.quotaLimited(retryAfterSeconds: 30))
    #expect(reply.contains("clawd auth login") == false)
    #expect(try harness.jobs.listAll().isEmpty)
  }

  @Test func accessDeniedParseFailureNeverTellsTheOwnerToLogIn() async throws {
    // given
    let harness = try makeHarness(parseResults: [.accessDenied])

    // when
    await parkDraft(harness)

    // then
    let reply = try #require(await harness.transport.sent.last?.text)
    #expect(reply == ScheduleReplies.accessDenied)
    #expect(reply.contains("clawd auth login") == false)
    #expect(try harness.jobs.listAll().isEmpty)
  }

  @Test func helpRendersTheCommandSetAndTheConfirmationRules() async throws {
    // given
    let harness = try makeHarness()

    // when
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "/help"))

    // then — the router emits the help text verbatim; its content is owned by CommandReplies.help
    let reply = try #require(await harness.transport.sent.last?.text)
    #expect(reply == CommandReplies.help)
  }

  @Test func strangersGetNoHelp() async throws {
    // given
    let harness = try makeHarness()

    // when
    await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "/help"))

    // then — never reveal capabilities to a stranger
    #expect(await harness.transport.sent.last?.text == MessageRouter.privateBotText)
  }
}
