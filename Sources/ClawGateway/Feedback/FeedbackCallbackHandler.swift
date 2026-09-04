import ClawCore
import Foundation
import Logging

/// Claims and authenticates one `fb:` tap before asking the learning store to consume its nonce.
public struct FeedbackCallbackHandler: Sendable {
  private let replies: ReplySender
  private let accessControl: AccessControl
  private let learning: any ScheduledLearningStore
  private let audit: any AuditLog
  private let callbacks: any CallbackResponding
  private let now: @Sendable () -> Date
  private let logger: Logger

  init(
    replies: ReplySender,
    accessControl: AccessControl,
    learning: any ScheduledLearningStore,
    audit: any AuditLog,
    callbacks: any CallbackResponding,
    now: @escaping @Sendable () -> Date,
    logger: Logger
  ) {
    self.replies = replies
    self.accessControl = accessControl
    self.learning = learning
    self.audit = audit
    self.callbacks = callbacks
    self.now = now
    self.logger = logger
  }

  public static func make(  // swiftlint:disable:this function_parameter_count
    processed: any ProcessedUpdateStore,
    delivery: any MessageDelivery,
    accessControl: AccessControl,
    learning: any ScheduledLearningStore,
    audit: any AuditLog,
    callbacks: any CallbackResponding,
    now: @escaping @Sendable () -> Date,
    logger: Logger
  ) -> FeedbackCallbackHandler {
    FeedbackCallbackHandler(
      replies: ReplySender(processed: processed, delivery: delivery, logger: logger),
      accessControl: accessControl,
      learning: learning,
      audit: audit,
      callbacks: callbacks,
      now: now,
      logger: logger
    )
  }

  public func handle(_ callback: RawCallback, updateId: Int64) async -> HandleOutcome {
    let noticeChatId = callback.chatId ?? callback.fromUserId
    do throws(RoutingHalt) {
      try await replies.claimUpdate(updateId: updateId, target: .chat(noticeChatId))
    } catch {
      return error.outcome
    }
    return await resolve(callback, updateId: updateId)
  }
}

// MARK: - Auth Chain

private extension FeedbackCallbackHandler {
  func resolve(_ callback: RawCallback, updateId: Int64) async -> HandleOutcome {
    guard accessControl.isAllowed(userId: callback.fromUserId) else {
      return await deny(callback, target: nil, signal: nil, decision: Self.forbiddenDecision)
    }
    guard let parsed = callback.data.flatMap(FeedbackKeyboard.parse) else {
      return await deny(callback, target: nil, signal: nil, decision: Self.malformedDecision)
    }

    return await resolveParsed(callback, parsed: parsed, updateId: updateId)
  }

  func resolveParsed(
    _ callback: RawCallback,
    parsed: (nonce: String, action: FeedbackAction),
    updateId: Int64
  ) async -> HandleOutcome {
    let target: FeedbackTarget?
    do {
      target = try learning.feedbackTarget(nonce: parsed.nonce)
    } catch {
      return await storeFailure(callback, signal: parsed.action.signal, error: error)
    }
    guard let target else {
      return await deny(
        callback,
        target: nil,
        signal: parsed.action.signal,
        decision: Self.unknownDecision
      )
    }
    guard callback.fromUserId == target.ownerUserId else {
      return await deny(
        callback,
        target: target,
        signal: parsed.action.signal,
        decision: Self.ownerMismatchDecision
      )
    }
    guard
      let callbackChatId = callback.chatId,
      callbackChatId == callback.fromUserId,
      target.chatId == callbackChatId
    else {
      return await deny(
        callback,
        target: target,
        signal: parsed.action.signal,
        decision: Self.chatMismatchDecision
      )
    }
    guard
      target.allowedActions.contains(parsed.action.signal),
      target.subjectKind == parsed.action.subjectKind
    else {
      return await deny(
        callback,
        target: target,
        signal: parsed.action.signal,
        decision: Self.actionMismatchDecision
      )
    }
    guard parsed.action.opensChallenge == false else {
      return await deny(
        callback,
        target: target,
        signal: parsed.action.signal,
        decision: Self.challengeUnavailableDecision
      )
    }
    return await consume(
      callback,
      target: target,
      signal: parsed.action.signal,
      updateId: updateId
    )
  }
}

// MARK: - Atomic Consumption

private extension FeedbackCallbackHandler {
  func consume(
    _ callback: RawCallback,
    target: FeedbackTarget,
    signal: OwnerSignal,
    updateId: Int64
  ) async -> HandleOutcome {
    let tap = FeedbackTap(
      nonce: target.nonce,
      signal: signal,
      ownerUserId: callback.fromUserId,
      chatId: target.chatId,
      transportUpdateId: updateId
    )
    let outcome: FeedbackOutcome
    do {
      outcome = try learning.consumeAndAppendEvent(tap, now: now())
    } catch {
      return await storeFailure(callback, signal: signal, error: error)
    }
    switch outcome {
    case .recorded:
      return await finish(callback, toast: Self.recordedToast)
    case .targetMissing, .ownerMismatch, .chatMismatch, .expired, .actionMismatch, .staleEpoch,
      .alreadyConsumed, .requiresPayloadChallenge:
      return await finish(callback, toast: Self.neutralToast)
    }
  }
}

// MARK: - Fail-Closed Responses

private extension FeedbackCallbackHandler {
  func deny(
    _ callback: RawCallback,
    target: FeedbackTarget?,
    signal: OwnerSignal?,
    decision: String
  ) async -> HandleOutcome {
    let actor: AuditActor = target?.ownerUserId == callback.fromUserId ? .owner : .system
    let event = AuditEvent(
      actor: actor,
      action: .learningFeedback,
      tool: signal?.rawValue,
      argsRedacted: Self.auditSubject(target),
      decision: decision,
      runId: Self.runId(target),
      ts: now()
    )
    do {
      try audit.appendAudit(event)
    } catch {
      logger.error("failed to audit rejected feedback callback: \(error)")
    }
    return await finish(callback, toast: Self.neutralToast)
  }

  func storeFailure(
    _ callback: RawCallback,
    signal: OwnerSignal?,
    error: any Error
  ) async -> HandleOutcome {
    logger.error("feedback callback store failure: \(error)")
    let event = AuditEvent(
      actor: .system,
      action: .learningFeedback,
      tool: signal?.rawValue,
      decision: Self.storeFailureDecision,
      ts: now()
    )
    do {
      try audit.appendAudit(event)
    } catch {
      logger.error("failed to audit feedback store failure: \(error)")
    }
    return await finish(callback, toast: Self.retryToast)
  }

  func finish(_ callback: RawCallback, toast: String) async -> HandleOutcome {
    do {
      try await callbacks.answerCallbackQuery(id: callback.callbackId, text: toast)
    } catch {
      logger.warning("failed to answer feedback callback \(callback.callbackId): \(error)")
    }
    return .processed
  }

  static func auditSubject(_ target: FeedbackTarget?) -> String {
    guard let target else {
      return ""
    }
    return "subject_kind=\(target.subjectKind.rawValue),subject_digest=\(target.subjectDigest)"
  }

  static func runId(_ target: FeedbackTarget?) -> Int64? {
    guard target?.subjectKind == .run else {
      return nil
    }
    return target.flatMap { value in
      Int64(value.subjectDigest)
    }
  }
}

// MARK: - Outcomes

private extension FeedbackCallbackHandler {
  static let forbiddenDecision = "forbidden"
  static let malformedDecision = "malformed"
  static let unknownDecision = "unknown"
  static let ownerMismatchDecision = "owner_mismatch"
  static let chatMismatchDecision = "chat_mismatch"
  static let actionMismatchDecision = "action_mismatch"
  static let challengeUnavailableDecision = "challenge_unavailable"
  static let storeFailureDecision = "store_failure"

  static let neutralToast = "This action is no longer available."
  static let retryToast = "Something went wrong — please try again."
  static let recordedToast = "Feedback recorded."
}
