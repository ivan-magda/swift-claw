import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct LearningRoutingTests {
  @Test func groupRefusesBeforeRead() async throws {
    // given
    let harness = try Harness.make(groupChats: [-1_001])
    try await harness.queue.write { db in
      try db.execute(sql: "DROP TABLE job_learning_state")
    }

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(
        id: 1,
        from: 42,
        chat: -1_001,
        text: "/learning",
        chatKind: .supergroup,
        messageThreadId: 7
      )
    )

    // then — making a read-only report room-safe reaches the deliberately broken reader.
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.map(\.text) == [CommandReplies.directOnly])
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func disabledServiceStillReadsAndResetDoesNotDispatch() async throws {
    // given — no ScheduledLearningService is passed to the router.
    let harness = try Harness.make()
    let job = try harness.createJob(label: "retained state")
    _ = try harness.learning.armJob(jobId: job.id, now: harness.now)
    let rowsBefore = try harness.learningRows()

    // when
    let detail = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/learning \(job.id)")
    )
    let validReset = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "/learning reset \(job.id)")
    )
    let invalidReset = await harness.router.handle(
      rawUpdate: textUpdate(id: 3, from: 42, text: "/learning reset")
    )

    // then — gating the view on the optional service hides retained state; reset must stay canned.
    #expect(detail == .processed)
    #expect(validReset == .processed)
    #expect(invalidReset == .processed)
    let texts = await harness.transport.sent.map(\.text)
    #expect(texts[0].contains("Schedule \(job.id) · retained state"))
    #expect(texts[1] == CommandReplies.learningResetUnavailable)
    #expect(texts[2] == CommandReplies.learningUsage)
    #expect(await harness.dispatcher.calls.isEmpty)
    #expect(try harness.learningRows() == rowsBefore)
  }

  @Test func redactsThenSplitsPlainTextWithoutLoss() async throws {
    // given
    let harness = try Harness.make(secretValues: ["x"])
    for index in 0..<40 {
      let job = try harness.createJob(
        label: "\(String(repeating: "x", count: 55))\(index)"
      )
      _ = try harness.learning.armJob(jobId: job.id, now: harness.now)
    }
    let raw = LearningSurface.render(
      try harness.learning.learningView(jobId: nil),
      style: .list
    )
    let expected = SecretRedactor(secretValues: ["x"]).redact(raw)

    // when
    let update = textUpdate(id: 1, from: 42, text: "/learning")
    let outcome = await harness.router.handle(rawUpdate: update)
    let firstBatch = await harness.transport.sent.map(\.text)
    let replay = await harness.router.handle(rawUpdate: update)

    // then — rich-limit, split-before-redact, truncation, reordering, or a chunk-path claim
    // bypass breaks these equalities; the nearest duplicate test reaches only the one-message path.
    #expect(outcome == .processed)
    #expect(replay == .skipped)
    let chunks = await harness.transport.sent.map(\.text)
    #expect(chunks.count > 1)
    #expect(chunks == firstBatch)
    #expect(
      chunks.allSatisfy { chunk in
        chunk.count <= TelegramMessageLimits.maxPlainMessageCharacters
      }
    )
    #expect(chunks.joined() == expected)
    #expect(chunks.joined().contains("x") == false)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func chunkClaimFailureRetriesWithoutDelivery() async throws {
    // given
    let harness = try Harness.make()
    let job = try harness.createJob(label: "claim failure")
    _ = try harness.learning.armJob(jobId: job.id, now: harness.now)
    try await harness.queue.write { db in
      try db.drop(table: "processed_updates")
    }

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/learning")
    )

    // then — sending before the multipart ownership claim leaks a reply for a retryable update;
    // the nearest claim-failure tests exercise other sender branches.
    #expect(outcome == .transientFailure)
    #expect(await harness.transport.sent.isEmpty)
    #expect(await harness.dispatcher.calls.isEmpty)
  }
}

private extension LearningRoutingTests {
  struct Harness {
    let queue: DatabaseQueue
    let router: MessageRouter
    let transport: RecordingTransport
    let dispatcher: FakeTurnRunner
    let jobs: ScheduledJobStoreGRDB
    let learning: ScheduledLearningStoreGRDB
    let now = Date(timeIntervalSince1970: 1_782_000_600)

    static func make(
      groupChats: Set<Int64> = [],
      secretValues: [String] = []
    ) throws -> Harness {
      let queue = try ClawDatabase.makeInMemoryQueue()
      try ClawDatabase.migrate(queue)
      let allowlist = AllowlistStoreGRDB(writer: queue)
      try allowlist.seedAllowlist(userIds: [42])
      let transport = RecordingTransport()
      let dispatcher = FakeTurnRunner()
      let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: false)
      let learning = ScheduledLearningStoreGRDB(writer: queue)
      let router = MessageRouter(
        processed: ProcessedUpdateStoreGRDB(writer: queue),
        sessionMessages: SessionMessageStoreGRDB(writer: queue),
        commands: CommandStoreGRDB(writer: queue),
        memory: MemoryStoreGRDB(writer: queue),
        memoryCommands: MemoryCommandStoreGRDB(writer: queue),
        pendingConfirmations: PendingConfirmationRegistry(),
        botIdentity: BotIdentity(id: 900, username: "claw_bot"),
        accessControl: AccessControl(allowlist: allowlist, groupChats: groupChats),
        delivery: transport,
        turnRunner: dispatcher,
        imageCache: ImageCache(),
        lanes: SessionLaneRegistry(),
        schedule: makeIdleScheduleSurface(writer: queue),
        learningStore: learning,
        learningRedactor: SecretRedactor(secretValues: secretValues),
        coordinator: ApprovalCoordinator(),
        doctor: StubDoctorReporter(),
        logger: TestLog.silent
      )
      return Harness(
        queue: queue,
        router: router,
        transport: transport,
        dispatcher: dispatcher,
        jobs: jobs,
        learning: learning
      )
    }

    func createJob(label: String) throws -> ScheduledJob {
      try jobs.create(
        NewScheduledJob(
          ownerChatId: 42,
          label: label,
          prompt: "Summarize",
          recurrence: nil,
          timezone: "Europe/Berlin",
          nextOccurrence: now
        ),
        now: now
      )
    }

    func learningRows() throws -> Int {
      try queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job_learning_state") ?? -1
      }
    }
  }
}
