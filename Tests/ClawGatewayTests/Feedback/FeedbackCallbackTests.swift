import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct FeedbackCallbackTests {
  @Test func parseIsStrictAndMapsEveryAction() throws {
    // given — every compact wire action and representative forged envelopes
    let expected: [(String, FeedbackAction, OwnerSignal, FeedbackSubjectKind)] = [
      ("ru", .resultUseful, .resultUseful, .run),
      ("rn", .resultNotUseful, .resultNotUseful, .run),
      ("rc", .resultCorrection, .resultCorrection, .run),
      ("ec", .evaluationConfirm, .evaluationConfirm, .evaluation),
      ("ed", .evaluationDispute, .evaluationDispute, .evaluation),
      ("ca", .candidateApprove, .candidateApprove, .candidate),
      ("cr", .candidateReject, .candidateReject, .candidate),
      ("ce", .candidateEdit, .candidateEdit, .candidate),
      ("pr", .promotionRollback, .promotionRollback, .promotion),
    ]

    // when / then — unknown, empty, foreign, short, and overlong shapes cannot survive parsing
    for (code, action, signal, subjectKind) in expected {
      let parsed = try #require(FeedbackKeyboard.parse("fb:abc:\(code)"))
      #expect(parsed.nonce == "abc")
      #expect(parsed.action == action)
      #expect(parsed.action.signal == signal)
      #expect(parsed.action.subjectKind == subjectKind)
    }
    #expect(FeedbackKeyboard.parse("fb:abc:zz") == nil)
    #expect(FeedbackKeyboard.parse("fb::ru") == nil)
    #expect(FeedbackKeyboard.parse("apr:abc:y") == nil)
    #expect(FeedbackKeyboard.parse("fb:abc") == nil)
    #expect(FeedbackKeyboard.parse("fb:abc:ru:extra") == nil)
  }

  @Test func allowlistRunsBeforeParsingAndEveryAuthRungFailsClosed() async throws {
    // given — every case reaches a distinct auth branch before atomic consumption
    let cases: [FeedbackAuthFailure] = [
      .forbidden,
      .malformed,
      .unknown,
      .ownerMismatch,
      .groupChat,
      .actionMismatch,
      .guessableTargetId,
    ]
    var neutralToasts: [String?] = []

    for failure in cases {
      let env = try FeedbackCallbackEnvironment.make(allowed: failure.allowedUsers)
      let target = env.target(
        nonce: "opaque-feedback-nonce",
        signal: .resultUseful,
        subject: "subject-digest"
      )
      _ = try env.learning.createTargets([target], chunks: [])
      let callback = failure.callback(target: target)

      // when
      let outcome = await env.handler.handle(callback, updateId: 10)

      // then — bypassing the named rung would consume the real target or classify it differently
      #expect(outcome == .processed)
      #expect(try env.eventCount() == 0)
      #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == nil)
      let audit = try #require(env.handlerAudit.events.last)
      #expect(audit.action == .learningFeedback)
      #expect(audit.decision == failure.decision)
      let answers = await env.callbacks.answers
      #expect(answers.count == 1)
      neutralToasts.append(answers.first?.text)
    }

    #expect(Set(neutralToasts).count == 1)
    #expect(neutralToasts.first == "This action is no longer available.")
  }

  @Test func knownAuthFailureAuditsTypedSubjectMetadataWithoutCallbackBytes() async throws {
    // given — an allowlisted non-owner and a known target
    let env = try FeedbackCallbackEnvironment.make(allowed: [42, 43])
    let target = env.target(
      nonce: "metadata-nonce",
      signal: .candidateReject,
      subject: "candidate-digest",
      kind: .candidate
    )
    _ = try env.learning.createTargets([target], chunks: [])
    let callback = env.callback(
      data: FeedbackKeyboard.callbackData(nonce: target.nonce, action: .candidateReject),
      from: 43,
      chat: 43
    )

    // when
    _ = await env.handler.handle(callback, updateId: 11)

    // then — dropping typed metadata or copying raw callback bytes into audit breaks this boundary
    let audit = try #require(env.handlerAudit.events.last)
    #expect(audit.actor == .system)
    #expect(audit.action == .learningFeedback)
    #expect(audit.tool == OwnerSignal.candidateReject.rawValue)
    #expect(audit.argsRedacted.contains(FeedbackSubjectKind.candidate.rawValue))
    #expect(audit.argsRedacted.contains(target.subjectDigest))
    #expect(audit.argsRedacted.contains(target.nonce) == false)
    #expect(audit.resultSize == 0)
  }

  @Test func validTapClaimsOnceAndConsumedNonceCannotAppendTwice() async throws {
    // given
    let env = try FeedbackCallbackEnvironment.make()
    let target = env.target(nonce: "single-use", signal: .resultUseful, subject: "41")
    _ = try env.learning.createTargets([target], chunks: [])
    let callback = env.callback(
      data: FeedbackKeyboard.callbackData(nonce: target.nonce, action: .resultUseful)
    )

    // when — one transport replay, then a distinct update tapping the consumed nonce
    let first = await env.handler.handle(callback, updateId: 7)
    let replay = await env.handler.handle(callback, updateId: 7)
    let secondTap = await env.handler.handle(callback, updateId: 8)

    // then — claiming inside the store too would make the first valid tap a duplicate
    #expect(first == .processed)
    #expect(replay == .skipped)
    #expect(secondTap == .processed)
    #expect(try env.eventCount() == 1)
    #expect(try env.feedbackRevision() == 1)
    #expect(try env.processedCount() == 2)
    let answers = await env.callbacks.answers
    #expect(answers.count == 2)
    #expect(answers.first?.text == "Feedback recorded.")
    #expect(answers.last?.text == "This action is no longer available.")
    let events = try env.learning.feedbackEvents(
      jobId: env.jobId,
      epoch: env.state.epoch,
      subjectKind: .run,
      subjectDigest: target.subjectDigest
    )
    #expect(events.first?.transportUpdateId == 7)
  }

  @Test func expiredTargetAnswersNeutrallyAndAuditsWithoutMutation() async throws {
    // given
    let env = try FeedbackCallbackEnvironment.make()
    let target = env.target(
      nonce: "expired",
      signal: .resultUseful,
      subject: "41",
      expiresAt: env.now
    )
    _ = try env.learning.createTargets([target], chunks: [])
    let callback = env.callback(
      data: FeedbackKeyboard.callbackData(nonce: target.nonce, action: .resultUseful)
    )

    // when
    let outcome = await env.handler.handle(callback, updateId: 12)

    // then — removing the expiry CAS would append and advance the revision
    #expect(outcome == .processed)
    #expect(try env.eventCount() == 0)
    #expect(try env.feedbackRevision() == 0)
    #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == nil)
    let audit = try #require(try env.databaseAudits().last)
    #expect(audit.action == AuditAction.learningFeedback.rawValue)
    #expect(audit.decision == "expired")
    #expect(await env.callbacks.answers.first?.text == "This action is no longer available.")
  }

  @Test func payloadActionsRemainAvailableForTheFutureChallengeBranch() async throws {
    // given — both pure payload-bearing buttons are valid and authenticated
    let actions: [(FeedbackAction, FeedbackSubjectKind)] = [
      (.resultCorrection, .run), (.candidateEdit, .candidate),
    ]

    for (offset, entry) in actions.enumerated() {
      let env = try FeedbackCallbackEnvironment.make()
      let target = env.target(
        nonce: "payload-\(offset)",
        signal: entry.0.signal,
        subject: "subject-\(offset)",
        kind: entry.1
      )
      _ = try env.learning.createTargets([target], chunks: [])
      let callback = env.callback(
        data: FeedbackKeyboard.callbackData(nonce: target.nonce, action: entry.0)
      )

      // when
      let outcome = await env.handler.handle(callback, updateId: Int64(20 + offset))

      // then — routing rc/ce to immediate consumption would destroy Task 11's live target
      #expect(outcome == .processed)
      #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == nil)
      #expect(try env.eventCount() == 0)
      #expect(try env.feedbackRevision() == 0)
      #expect(env.handlerAudit.events.last?.decision == "challenge_unavailable")
      #expect(await env.callbacks.answers.first?.text == "This action is no longer available.")
    }
  }

  @Test func routerOwnsMalformedFeedbackDomainWithoutPreParsingIt() async throws {
    // given — a malformed fb envelope and a router with only the feedback callback handler wired
    let env = try FeedbackCallbackEnvironment.make(wireRouter: true)
    let update = RawUpdate(
      updateId: 30,
      message: nil,
      editedMessage: nil,
      callback: env.callback(data: "fb:known:unknown")
    )

    // when
    let outcome = await env.router.handle(rawUpdate: update)

    // then — strict parsing in the router would skip before the handler can claim, audit, and toast
    #expect(outcome == .processed)
    #expect(try env.processedCount() == 1)
    #expect(env.handlerAudit.events.last?.action == .learningFeedback)
    #expect(env.handlerAudit.events.last?.decision == "malformed")
    #expect(await env.callbacks.answers.first?.text == "This action is no longer available.")
  }
}

private enum FeedbackAuthFailure {
  case forbidden
  case malformed
  case unknown
  case ownerMismatch
  case groupChat
  case actionMismatch
  case guessableTargetId

  var allowedUsers: [Int64] {
    switch self {
    case .ownerMismatch:
      [42, 43]
    case .forbidden, .malformed, .unknown, .groupChat, .actionMismatch, .guessableTargetId:
      [42]
    }
  }

  var decision: String {
    switch self {
    case .forbidden: "forbidden"
    case .malformed: "malformed"
    case .unknown, .guessableTargetId: "unknown"
    case .ownerMismatch: "owner_mismatch"
    case .groupChat: "chat_mismatch"
    case .actionMismatch: "action_mismatch"
    }
  }

  func callback(target: NewFeedbackTarget) -> RawCallback {
    let useful = FeedbackKeyboard.callbackData(nonce: target.nonce, action: .resultUseful)
    switch self {
    case .forbidden:
      return RawCallback(
        callbackId: "forbidden",
        fromUserId: 999,
        chatId: 999,
        messageId: 1,
        data: "fb:malformed"
      )
    case .malformed:
      return RawCallback(
        callbackId: "malformed",
        fromUserId: 42,
        chatId: 42,
        messageId: 1,
        data: "fb:malformed"
      )
    case .unknown:
      return RawCallback(
        callbackId: "unknown",
        fromUserId: 42,
        chatId: 42,
        messageId: 1,
        data: FeedbackKeyboard.callbackData(nonce: "missing", action: .resultUseful)
      )
    case .ownerMismatch:
      return RawCallback(
        callbackId: "owner",
        fromUserId: 43,
        chatId: 43,
        messageId: 1,
        data: useful
      )
    case .groupChat:
      return RawCallback(
        callbackId: "group",
        fromUserId: 42,
        chatId: -1_000,
        messageId: 1,
        data: useful
      )
    case .actionMismatch:
      return RawCallback(
        callbackId: "action",
        fromUserId: 42,
        chatId: 42,
        messageId: 1,
        data: FeedbackKeyboard.callbackData(nonce: target.nonce, action: .resultNotUseful)
      )
    case .guessableTargetId:
      return RawCallback(
        callbackId: "row-id",
        fromUserId: 42,
        chatId: 42,
        messageId: 1,
        data: FeedbackKeyboard.callbackData(nonce: "1", action: .resultUseful)
      )
    }
  }
}

private struct FeedbackCallbackEnvironment {
  struct AuditRow {
    let action: String
    let decision: String
  }

  let queue: DatabaseQueue
  let learning: ScheduledLearningStoreGRDB
  let state: JobLearningState
  let jobId: Int64
  let now: Date
  let handlerAudit: RecordingAuditLog
  let callbacks: RecordingCallbacks
  let handler: FeedbackCallbackHandler
  let router: MessageRouter

  static func make(
    allowed: [Int64] = [42],
    wireRouter: Bool = false
  ) throws -> FeedbackCallbackEnvironment {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatId: 42,
        label: "feedback",
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
    try allowlist.seedAllowlist(userIds: allowed)
    let access = AccessControl(allowlist: allowlist, groupChats: [])
    let handlerAudit = RecordingAuditLog()
    let callbacks = RecordingCallbacks()
    let processed = ProcessedUpdateStoreGRDB(writer: queue)
    let delivery = RecordingTransport()
    let handler = FeedbackCallbackHandler(
      replies: ReplySender(processed: processed, delivery: delivery, logger: TestLog.silent),
      accessControl: access,
      learning: learning,
      audit: handlerAudit,
      callbacks: callbacks,
      now: { now },
      logger: TestLog.silent
    )
    let router = MessageRouter(
      processed: processed,
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botIdentity: BotIdentity(id: 900, username: "claw_bot"),
      accessControl: access,
      delivery: delivery,
      turnRunner: FakeTurnRunner(),
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      feedbackCallbacks: wireRouter ? handler : nil,
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      logger: TestLog.silent
    )
    return FeedbackCallbackEnvironment(
      queue: queue,
      learning: learning,
      state: state,
      jobId: job.id,
      now: now,
      handlerAudit: handlerAudit,
      callbacks: callbacks,
      handler: handler,
      router: router
    )
  }

  func target(
    nonce: String,
    signal: OwnerSignal,
    subject: String,
    kind: FeedbackSubjectKind = .run,
    expiresAt: Date? = nil
  ) -> NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: nonce,
      jobId: jobId,
      epoch: state.epoch,
      subjectKind: kind,
      subjectDigest: subject,
      allowedActions: [signal],
      ownerUserId: 42,
      chatId: 42,
      expiresAt: expiresAt ?? now.addingTimeInterval(3_600)
    )
  }

  func callback(data: String?, from: Int64 = 42, chat: Int64 = 42) -> RawCallback {
    RawCallback(
      callbackId: "feedback-callback",
      fromUserId: from,
      chatId: chat,
      messageId: 1,
      data: data
    )
  }

  func eventCount() throws -> Int {
    try count(table: "feedback_events")
  }

  func processedCount() throws -> Int {
    try count(table: "processed_updates")
  }

  func count(table: String) throws -> Int {
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

  func databaseAudits() throws -> [AuditRow] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT action, decision FROM audit_events WHERE action = ? ORDER BY id",
        arguments: [AuditAction.learningFeedback.rawValue]
      ).map { row in
        AuditRow(action: row["action"], decision: row["decision"])
      }
    }
  }
}
