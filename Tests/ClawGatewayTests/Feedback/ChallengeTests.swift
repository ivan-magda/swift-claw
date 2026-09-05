import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct ChallengeTests {
  @Test func tappingCorrectionDefersTheEventAndConsumesTheNextOwnerMessageExactlyOnce() async throws
  {
    // given — one authenticated result-correction target
    let env = try ChallengeEnvironment.make()
    let target = env.target(
      nonce: "router-correction",
      expiresAt: env.now.addingTimeInterval(3_600)
    )
    try env.learning.createTargets([target], chunks: [], now: env.now)

    // when — the owner taps but has not supplied the payload yet
    let tapOutcome = await env.router.handle(rawUpdate: env.callback(target: target, updateId: 1))
    let tapReplay = await env.router.handle(rawUpdate: env.callback(target: target, updateId: 1))
    let freshTapReplay = await env.router.handle(
      rawUpdate: env.callback(target: target, updateId: 2)
    )

    // then — target, challenge, and prompt committed; no semantic event or revision did
    #expect(tapOutcome == .processed)
    #expect(tapReplay == .skipped)
    #expect(freshTapReplay == .processed)
    #expect(try env.eventCount() == 0)
    #expect(try env.feedbackRevision() == 0)
    #expect(try env.learning.liveChallenge(ownerUserId: env.ownerId, chatId: env.chatId) != nil)
    #expect(try env.pendingDeliveries().count == 1)
    let promptSurfaces = try env.pendingDeliveries().map { row in
      [row.deliveryKey, row.payload, row.replyMarkup ?? ""].joined()
    }.joined()
    #expect(promptSurfaces.contains(target.nonce) == false)
    #expect(env.pokes.count == 1)

    // when — Telegram replays the payload update, then a distinct message arrives
    let payload = "It missed the price change."
    let first = await env.router.handle(
      rawUpdate: textUpdate(id: 3, from: env.ownerId, text: payload)
    )
    let replay = await env.router.handle(
      rawUpdate: textUpdate(id: 3, from: env.ownerId, text: payload)
    )
    let ordinary = await env.router.handle(
      rawUpdate: textUpdate(id: 4, from: env.ownerId, text: "Anything else?")
    )
    await env.turns.waitForCalls(atLeast: 1)

    // then — only the first text is feedback; the second distinct text starts today's turn
    #expect(first == .processed)
    #expect(replay == .skipped)
    #expect(ordinary == .processed)
    #expect(try env.eventPayloads() == [payload])
    #expect(try env.eventTransportIds() == [nil])
    #expect(try env.feedbackRevision() == 1)
    #expect(await env.turns.calls.count == 1)
    #expect(try env.processedCount() == 4)
    let sentText = await env.transport.sent.map(\.text).joined()
    #expect(sentText.contains(payload) == false)
    let logged = env.logs.entries.map(\.message).joined()
    #expect(logged.contains(payload) == false)
    #expect(logged.contains(target.nonce) == false)
  }

  @Test func challengeInterceptsOwnerTextBeforeCommandParsing() async throws {
    // given — a live challenge and a command-shaped owner payload
    let env = try ChallengeEnvironment.make()
    try await env.openChallenge(nonce: "before-command")

    // when
    let outcome = await env.router.handle(
      rawUpdate: textUpdate(id: 2, from: env.ownerId, text: "/new")
    )

    // then — parsing first would supersede the session instead of recording these exact bytes
    #expect(outcome == .processed)
    #expect(try env.eventPayloads() == ["/new"])
    #expect(await env.turns.calls.isEmpty)
  }

  @Test func challengeOpenedBeforeEpochAdvanceCannotAppendFeedback() async throws {
    // given
    let env = try ChallengeEnvironment.make()
    try await env.openChallenge(nonce: "stale-epoch")
    try env.advanceLearningEpoch()

    // when
    let outcome = await env.router.handle(
      rawUpdate: textUpdate(id: 2, from: env.ownerId, text: "too late")
    )

    // then — the in-transaction epoch CAS rejects the already claimed owner message
    #expect(outcome == .processed)
    #expect(try env.eventCount() == 0)
    #expect(try env.feedbackRevision() == 0)
    #expect(await env.turns.calls.isEmpty)
  }

  @Test func expiredChallengeFallsThroughToAnOrdinaryTurnWithoutClaimingFirst() async throws {
    // given — the challenge expires exactly at the handler's captured clock
    let env = try ChallengeEnvironment.make()
    let expiresAt = env.now.addingTimeInterval(10)
    try await env.openChallenge(nonce: "expired-router", expiresAt: expiresAt)
    env.clock.advance(to: expiresAt)
    let text = "today's ordinary turn"

    // when
    let outcome = await env.router.handle(
      rawUpdate: textUpdate(id: 2, from: env.ownerId, text: text)
    )

    // then — the ordinary path persists its inbound and run before returning
    #expect(outcome == .processed)
    #expect(try env.persistedTurnCount(text: text) == 1)
    #expect(try env.eventCount() == 0)
    #expect(try env.processedCount() == 2)
  }

  @Test func failedChallengeTransactionDoesNotPokeTheOutbox() async throws {
    // given — the prompt's exact outbox identity is already occupied
    let env = try ChallengeEnvironment.make()
    let target = env.target(nonce: "failed-prompt", expiresAt: env.now.addingTimeInterval(3_600))
    try env.learning.createTargets([target], chunks: [], now: env.now)
    let tap = env.tap(target: target, updateId: 1)
    let prompt = LearningNotices.challengePrompt(for: tap)
    try env.learning.createTargets([], chunks: prompt, now: env.now)

    // when
    let outcome = await env.router.handle(rawUpdate: env.callback(target: target, updateId: 1))

    // then — an eager or unconditional poke advertises a transaction that rolled back
    #expect(outcome == .processed)
    #expect(env.pokes.count == Int.zero)
    #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == nil)
    #expect(try env.learning.liveChallenge(ownerUserId: env.ownerId, chatId: env.chatId) == nil)
  }

  @Test func resultKeyboardContainsExactlyTheThreeRunActionsInOrder() throws {
    // given
    let target = NewFeedbackTarget(
      nonce: "keyboard-nonce",
      jobId: 1,
      epoch: LearningEpoch(1),
      subjectKind: .run,
      subjectDigest: "41",
      allowedActions: [.resultUseful, .resultNotUseful, .resultCorrection],
      ownerUserId: 42,
      chatId: 42,
      expiresAt: .distantFuture
    )

    // when
    let keyboard = LearningNotices.resultKeyboard(target: target)

    // then — adding, removing, or reordering a candidate/evaluation action breaks this surface
    let expectedCallbacks = [
      FeedbackAction.resultUseful,
      FeedbackAction.resultNotUseful,
      FeedbackAction.resultCorrection,
    ].map { action in
      FeedbackKeyboard.callbackData(nonce: target.nonce, action: action)
    }
    let envelope = try JSONDecoder().decode(KeyboardEnvelope.self, from: Data(keyboard.utf8))
    #expect(envelope.inlineKeyboard.count == 1)
    let buttons = envelope.inlineKeyboard[0]
    #expect(buttons.count == 3)
    #expect(buttons.map(\.callbackData) == expectedCallbacks)
  }
}

private struct KeyboardEnvelope: Decodable {
  let inlineKeyboard: [[KeyboardButton]]

  private enum CodingKeys: String, CodingKey {
    case inlineKeyboard = "inline_keyboard"
  }
}

private struct KeyboardButton: Decodable {
  let callbackData: String

  private enum CodingKeys: String, CodingKey {
    case callbackData = "callback_data"
  }
}

// MARK: - Fixtures

private struct ChallengeEnvironment {
  let queue: DatabaseQueue
  let learning: ScheduledLearningStoreGRDB
  let state: JobLearningState
  let jobId: Int64
  let ownerId: Int64
  let chatId: Int64
  let clock: ManualClock
  let transport: RecordingTransport
  let logs: RecordingLogCapture
  let turns: FakeTurnRunner
  let pokes: PokeRecorder
  let router: MessageRouter

  var now: Date { clock.now }

  static func make() throws -> ChallengeEnvironment {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let ownerId: Int64 = 42
    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatId: ownerId,
        label: "challenge",
        prompt: "Summarize updates",
        recurrence: nil,
        timezone: "UTC",
        nextOccurrence: now
      ),
      now: now
    )
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    let state = try learning.armJob(jobId: job.id, now: now)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: [ownerId])
    let access = AccessControl(allowlist: allowlist, groupChats: [])
    let transport = RecordingTransport()
    let processed = ProcessedUpdateStoreGRDB(writer: queue)
    let clock = ManualClock(startAt: now)
    let pokes = PokeRecorder()
    let logs = RecordingLogCapture()
    let logger = logs.logger()
    let challenges = FeedbackChallengeHandler(
      replies: ReplySender(processed: processed, delivery: transport, logger: logger),
      learning: learning,
      notifyOutbox: { pokes.record() },
      now: { clock.now }
    )
    let callbacks = FeedbackCallbackHandler(
      replies: ReplySender(processed: processed, delivery: transport, logger: logger),
      accessControl: access,
      learning: learning,
      audit: AuditLogGRDB(writer: queue),
      callbacks: transport,
      challenges: challenges,
      now: { clock.now },
      logger: logger
    )
    let turns = FakeTurnRunner()
    let router = MessageRouter(
      processed: processed,
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botIdentity: BotIdentity(id: 900, username: "claw_bot"),
      accessControl: access,
      delivery: transport,
      turnRunner: turns,
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      feedbackCallbacks: callbacks,
      feedbackChallenges: challenges,
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      now: { clock.now },
      logger: logger
    )
    return ChallengeEnvironment(
      queue: queue,
      learning: learning,
      state: state,
      jobId: job.id,
      ownerId: ownerId,
      chatId: ownerId,
      clock: clock,
      transport: transport,
      logs: logs,
      turns: turns,
      pokes: pokes,
      router: router
    )
  }
}

private extension ChallengeEnvironment {
  func target(nonce: String, expiresAt: Date) -> NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: nonce,
      jobId: jobId,
      epoch: state.epoch,
      subjectKind: .run,
      subjectDigest: "41",
      allowedActions: [.resultCorrection],
      ownerUserId: ownerId,
      chatId: chatId,
      expiresAt: expiresAt
    )
  }

  func callback(target: NewFeedbackTarget, updateId: Int64) -> RawUpdate {
    RawUpdate(
      updateId: updateId,
      message: nil,
      editedMessage: nil,
      callback: RawCallback(
        callbackId: "challenge-\(updateId)",
        fromUserId: ownerId,
        chatId: chatId,
        messageId: 100,
        data: FeedbackKeyboard.callbackData(nonce: target.nonce, action: .resultCorrection)
      )
    )
  }

  func tap(target: NewFeedbackTarget, updateId: Int64) -> FeedbackTap {
    FeedbackTap(
      nonce: target.nonce,
      signal: .resultCorrection,
      ownerUserId: ownerId,
      chatId: chatId,
      transportUpdateId: updateId
    )
  }

  func openChallenge(nonce: String, expiresAt: Date? = nil) async throws {
    let target = target(
      nonce: nonce,
      expiresAt: expiresAt ?? now.addingTimeInterval(3_600)
    )
    try learning.createTargets([target], chunks: [], now: now)
    let outcome = await router.handle(rawUpdate: callback(target: target, updateId: 1))
    #expect(outcome == .processed)
    #expect(try learning.liveChallenge(ownerUserId: ownerId, chatId: chatId) != nil)
  }

  func eventCount() throws -> Int {
    try rowCount(table: "feedback_events")
  }

  func processedCount() throws -> Int {
    try rowCount(table: "processed_updates")
  }

  func persistedTurnCount(text: String) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM runs
          JOIN messages ON messages.id = runs.trigger_message_id
          WHERE messages.content = ? AND messages.role = ?
          """,
        arguments: [text, MessageRole.user.rawValue]
      ) ?? -1
    }
  }

  func rowCount(table: String) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
    }
  }

  func feedbackRevision() throws -> Int64 {
    try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT feedback_revision FROM job_learning_state WHERE job_id = ?",
        arguments: [jobId]
      ) ?? -1
    }
  }

  func eventPayloads() throws -> [String] {
    try queue.read { db in
      try String.fetchAll(db, sql: "SELECT payload FROM feedback_events ORDER BY event_id")
    }
  }

  func eventTransportIds() throws -> [Int64?] {
    try queue.read { db in
      try Int64?.fetchAll(
        db,
        sql: "SELECT transport_update_id FROM feedback_events ORDER BY event_id"
      )
    }
  }

  func pendingDeliveries() throws -> [OutboxRow] {
    try OutboxStoreGRDB(writer: queue).pendingOutbound()
  }

  func advanceLearningEpoch() throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET learning_epoch = learning_epoch + 1 WHERE job_id = ?",
        arguments: [jobId]
      )
    }
  }
}

private final class PokeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func record() {
    lock.lock()
    defer { lock.unlock() }
    recorded += 1
  }
}
