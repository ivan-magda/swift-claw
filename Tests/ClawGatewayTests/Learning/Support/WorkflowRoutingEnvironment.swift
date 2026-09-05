import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB

@testable import ClawGateway

extension EvaluationRunEnvironment {
  func workflowRouter(service: ScheduledLearningService) throws -> MessageRouter {
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: [Self.chatId])
    let access = AccessControl(allowlist: allowlist, groupChats: [])
    let transport = RecordingTransport()
    let processed = ProcessedUpdateStoreGRDB(writer: queue)
    let challenges = FeedbackChallengeHandler.make(
      processed: processed,
      delivery: transport,
      learning: learning,
      workflow: service,
      notifyOutbox: {},
      now: { now },
      logger: TestLog.silent
    )
    let callbacks = FeedbackCallbackHandler.make(
      processed: processed,
      delivery: transport,
      accessControl: access,
      learning: learning,
      audit: AuditLogGRDB(writer: queue),
      callbacks: transport,
      challenges: challenges,
      workflow: service,
      now: { now },
      logger: TestLog.silent
    )
    return MessageRouter(
      processed: processed,
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botIdentity: BotIdentity(id: 900, username: "claw_bot"),
      accessControl: access,
      delivery: transport,
      turnRunner: FakeTurnRunner(),
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      learning: service,
      learningStore: learning,
      learningRedactor: SecretRedactor(secretValues: []),
      learningOutboxSignal: OutboxSignal(),
      feedbackCallbacks: callbacks,
      feedbackChallenges: challenges,
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      now: { now },
      logger: TestLog.silent
    )
  }

  func callback(target: FeedbackTarget, action: FeedbackAction, id: Int64) -> RawUpdate {
    RawUpdate(
      updateId: id,
      message: nil,
      editedMessage: nil,
      callback: RawCallback(
        callbackId: "workflow-\(id)",
        fromUserId: Self.chatId,
        chatId: Self.chatId,
        messageId: 100,
        data: FeedbackKeyboard.callbackData(nonce: target.nonce, action: action)
      )
    )
  }

  func promotionTarget() throws -> FeedbackTarget? {
    let nonce = try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT nonce FROM feedback_targets WHERE subject_kind = ?",
        arguments: [FeedbackSubjectKind.promotion.rawValue]
      )
    }
    return try nonce.flatMap { value in
      try learning.feedbackTarget(nonce: value)
    }
  }
}
