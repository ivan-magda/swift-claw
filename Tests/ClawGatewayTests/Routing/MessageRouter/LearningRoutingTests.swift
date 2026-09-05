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

  @Test func disabledServiceStillReadsAndResetRequiresOwnerConfirmation() async throws {
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

    // then — gating this provider-free path on the optional worker would strand retained state.
    #expect(detail == .processed)
    #expect(validReset == .processed)
    #expect(invalidReset == .processed)
    let texts = await harness.transport.sent.map(\.text)
    #expect(texts[0].contains("Schedule \(job.id) · retained state"))
    let prompt = texts[1]
    #expect(prompt.contains("Reset its learning?"))
    #expect(prompt.contains("new learning epoch with an empty stable lesson set"))
    #expect(prompt.contains("close every live trial"))
    #expect(prompt.contains("invalidate pending feedback targets and challenges"))
    #expect(prompt.contains("learning calls that have not started"))
    #expect(prompt.contains("Calls already in flight may finish, but only their usage is retained"))
    #expect(prompt.contains("Existing runs keep the lessons they were pinned to"))
    #expect(prompt.contains("learning history is retained"))
    #expect(prompt.contains("exact current effects are resolved when you confirm"))
    #expect(texts[2] == CommandReplies.learningUsage)
    #expect(await harness.dispatcher.calls.isEmpty)
    #expect(try harness.learningRows() == rowsBefore)

    // when
    let confirmed = await harness.router.handle(rawUpdate: textUpdate(id: 4, from: 42, text: "yes"))

    // then — only the fused confirmation update raises the barrier.
    #expect(confirmed == .processed)
    #expect(try harness.learningEpoch(jobId: job.id) == LearningEpoch(2))
    #expect((await harness.transport.sent.last?.text)?.contains("Learning reset applied") == true)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func missingAndUnarmedResetDoNotReplaceAnExistingConfirmation() async throws {
    // given
    let harness = try Harness.make()
    let armed = try harness.createJob(label: "armed")
    _ = try harness.learning.armJob(jobId: armed.id, now: harness.now)
    let unarmed = try harness.createJob(label: "unarmed")
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 10, from: 42, text: "/learning reset \(armed.id)")
    )
    let sessionId = try harness.ownerSessionId()
    let parked = await harness.pendingConfirmations.pending(sessionId: sessionId)

    // when
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 11, from: 42, text: "/learning reset \(unarmed.id)")
    )
    let afterUnarmed = await harness.pendingConfirmations.pending(sessionId: sessionId)
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 12, from: 42, text: "/learning reset 99999")
    )
    let afterMissing = await harness.pendingConfirmations.pending(sessionId: sessionId)

    // then — parking before the one-snapshot boundary would displace a valid pending reset.
    #expect(parked == .learningReset(jobId: armed.id))
    #expect(afterUnarmed == parked)
    #expect(afterMissing == parked)
    let texts = await harness.transport.sent.map(\.text)
    #expect(texts[1].contains("learning state: not created"))
    #expect(texts[2] == "No schedule with id 99999. See /schedule list.")
  }

  @Test func unreadableStateCanStillBeWithdrawnThroughReset() async throws {
    // given
    let harness = try Harness.make(secretValues: ["secret-label"])
    let job = try harness.createJob(label: "secret-label")
    _ = try harness.learning.armJob(jobId: job.id, now: harness.now)
    try harness.insertUnreadableCurrentDecision(jobId: job.id)
    #expect(try harness.learning.learningView(jobId: job.id).isOnlyUnreadable)

    // when
    let parked = await harness.router.handle(
      rawUpdate: textUpdate(id: 20, from: 42, text: "/learning reset \(job.id)")
    )
    let confirmed = await harness.router.handle(
      rawUpdate: textUpdate(id: 21, from: 42, text: "yes")
    )

    // then — requiring a readable prior decision prevents the owner from fencing damaged state.
    #expect(parked == .processed)
    #expect(confirmed == .processed)
    let prompt = await harness.transport.sent.first?.text
    #expect(prompt?.contains(SecretRedactor.replacement) == true)
    #expect(prompt?.contains("secret-label") == false)
    #expect(try harness.learningEpoch(jobId: job.id) == LearningEpoch(2))
    #expect(try harness.learning.learningView(jobId: job.id).onlyReadable != nil)
  }

  @Test func redeliveredOldYesDoesNotClearANewerResetSlot() async throws {
    // given
    let harness = try Harness.make()
    let first = try harness.createJob(label: "first")
    let second = try harness.createJob(label: "second")
    _ = try harness.learning.armJob(jobId: first.id, now: harness.now)
    _ = try harness.learning.armJob(jobId: second.id, now: harness.now)
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 30, from: 42, text: "/learning reset \(first.id)")
    )
    let oldYes = textUpdate(id: 31, from: 42, text: "yes")
    _ = await harness.router.handle(rawUpdate: oldYes)
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 32, from: 42, text: "/learning reset \(second.id)")
    )
    let sessionId = try harness.ownerSessionId()

    // when
    let replay = await harness.router.handle(rawUpdate: oldYes)

    // then — clearing before the fused claim result lets a stale delivery erase newer intent.
    #expect(replay == .skipped)
    #expect(try harness.learningEpoch(jobId: second.id) == LearningEpoch(1))
    #expect(
      await harness.pendingConfirmations.pending(sessionId: sessionId)
        == .learningReset(jobId: second.id)
    )
  }

  @Test(arguments: ResetConfirmationRace.allCases)
  func confirmationResolvesTheCurrentResetOutcome(_ race: ResetConfirmationRace) async throws {
    // given
    let harness = try Harness.make()
    let job = try harness.createJob(label: "resolution race")
    _ = try harness.learning.armJob(jobId: job.id, now: harness.now)
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 35, from: 42, text: "/learning reset \(job.id)")
    )
    switch race {
    case .alreadyReset:
      _ = try harness.learning.applyReset(updateId: 3_500, jobId: job.id, now: harness.now)
    case .unarmed:
      try await harness.queue.write { db in
        try db.execute(sql: "DELETE FROM job_learning_state WHERE job_id = ?", arguments: [job.id])
      }
    case .notFound:
      try await harness.queue.write { db in
        try db.execute(sql: "DELETE FROM job_learning_state WHERE job_id = ?", arguments: [job.id])
        try db.execute(sql: "DELETE FROM scheduled_jobs WHERE id = ?", arguments: [job.id])
      }
    }

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 36, from: 42, text: "yes"))

    // then — resolving the preview snapshot instead of the confirmation-time outcome reports a
    // reset that did not occur, or hides a reset another serialized writer already completed.
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.last?.text == race.expectedReply(jobId: job.id))
  }

  @Test func resetCommitFailureClaimsAndClearsWithNothingChanged() async throws {
    // given
    let harness = try Harness.make()
    let job = try harness.createJob(label: "rollback")
    _ = try harness.learning.armJob(jobId: job.id, now: harness.now)
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 40, from: 42, text: "/learning reset \(job.id)")
    )
    try harness.failResetAudit()
    let sessionId = try harness.ownerSessionId()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 41, from: 42, text: "yes")
    )

    // then — acknowledging success or keeping a terminally failed slot misstates the rollback.
    #expect(outcome == .processed)
    #expect(try harness.learningEpoch(jobId: job.id) == LearningEpoch(1))
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) == nil)
    #expect(await harness.transport.sent.last?.text == LearningReplies.resetFailed)
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

extension LearningRoutingTests {
  struct Harness {
    let queue: DatabaseQueue
    let router: MessageRouter
    let transport: RecordingTransport
    let dispatcher: FakeTurnRunner
    let jobs: ScheduledJobStoreGRDB
    let learning: ScheduledLearningStoreGRDB
    let pendingConfirmations: PendingConfirmationRegistry
    let now = Date(timeIntervalSince1970: 1_782_000_600)

    static func make(
      groupChats: Set<Int64> = [],
      secretValues: [String] = [],
      outboxSignal: OutboxSignal? = nil
    ) throws -> Harness {
      let queue = try ClawDatabase.makeInMemoryQueue()
      try ClawDatabase.migrate(queue)
      let allowlist = AllowlistStoreGRDB(writer: queue)
      try allowlist.seedAllowlist(userIds: [42])
      let transport = RecordingTransport()
      let dispatcher = FakeTurnRunner()
      let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: false)
      let learning = ScheduledLearningStoreGRDB(writer: queue)
      let pendingConfirmations = PendingConfirmationRegistry()
      let router = MessageRouter(
        processed: ProcessedUpdateStoreGRDB(writer: queue),
        sessionMessages: SessionMessageStoreGRDB(writer: queue),
        commands: CommandStoreGRDB(writer: queue),
        memory: MemoryStoreGRDB(writer: queue),
        memoryCommands: MemoryCommandStoreGRDB(writer: queue),
        pendingConfirmations: pendingConfirmations,
        botIdentity: BotIdentity(id: 900, username: "claw_bot"),
        accessControl: AccessControl(allowlist: allowlist, groupChats: groupChats),
        delivery: transport,
        turnRunner: dispatcher,
        imageCache: ImageCache(),
        lanes: SessionLaneRegistry(),
        schedule: makeIdleScheduleSurface(writer: queue),
        learningStore: learning,
        learningRedactor: SecretRedactor(secretValues: secretValues),
        learningOutboxSignal: outboxSignal,
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
        learning: learning,
        pendingConfirmations: pendingConfirmations
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

    func learningEpoch(jobId: Int64) throws -> LearningEpoch? {
      try queue.read { db in
        try Int64.fetchOne(
          db,
          sql: "SELECT learning_epoch FROM job_learning_state WHERE job_id = ?",
          arguments: [jobId]
        ).map(LearningEpoch.init)
      }
    }

    func ownerSessionId() throws -> Int64 {
      let sessionId = try SessionMessageStoreGRDB(writer: queue).findSession(
        sessionKey: SessionKey.telegramDM(chatId: 42)
      )
      guard let sessionId else {
        throw StoreError.unexpected("owner session is missing")
      }
      return sessionId
    }

    func insertUnreadableCurrentDecision(jobId: Int64) throws {
      try queue.write { db in
        try db.execute(
          sql: """
            INSERT INTO learning_decisions(kind, job_id, learning_epoch, inputs, result,
              algorithm, decided_at)
            VALUES ('unknown', ?, 1, '{}', '{}', ?, ?)
            """,
          arguments: [jobId, LearningAlgorithm.v1.rawValue, now]
        )
      }
    }

    func failResetAudit() throws {
      try queue.write { db in
        try db.execute(
          sql: """
            CREATE TRIGGER fail_reset_audit BEFORE INSERT ON audit_events
            WHEN NEW.action = '\(AuditAction.learningReset.rawValue)'
            BEGIN SELECT RAISE(ABORT, 'forced reset audit failure'); END
            """
        )
      }
    }
  }
}

enum ResetConfirmationRace: CaseIterable {
  case alreadyReset
  case unarmed
  case notFound

  func expectedReply(jobId: Int64) -> String {
    switch self {
    case .alreadyReset:
      "Learning for schedule \(jobId) was already reset at epoch 2."
    case .unarmed:
      "Schedule \(jobId) has no learning state to reset."
    case .notFound:
      "No schedule with id \(jobId). Nothing was reset."
    }
  }
}

private extension Array where Element == JobLearningView {
  var onlyReadable: ReadableJobLearningView? {
    guard count == 1, case .readable(let view) = self[0] else {
      return nil
    }
    return view
  }

  var isOnlyUnreadable: Bool {
    guard count == 1, case .unreadable = self[0] else {
      return false
    }
    return true
  }
}
