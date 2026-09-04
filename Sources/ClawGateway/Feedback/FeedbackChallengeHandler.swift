import ClawCore
import Foundation
import Logging

/// Opens a durable payload challenge and intercepts exactly the next owner DM while it is live.
public struct FeedbackChallengeHandler: Sendable {
  private let replies: ReplySender
  private let learning: any ScheduledLearningStore
  private let notifyOutbox: @Sendable () -> Void
  private let now: @Sendable () -> Date

  init(
    replies: ReplySender,
    learning: any ScheduledLearningStore,
    notifyOutbox: @escaping @Sendable () -> Void,
    now: @escaping @Sendable () -> Date
  ) {
    self.replies = replies
    self.learning = learning
    self.notifyOutbox = notifyOutbox
    self.now = now
  }

  public static func make(  // swiftlint:disable:this function_parameter_count
    processed: any ProcessedUpdateStore,
    delivery: any MessageDelivery,
    learning: any ScheduledLearningStore,
    notifyOutbox: @escaping @Sendable () -> Void,
    now: @escaping @Sendable () -> Date,
    logger: Logger
  ) -> FeedbackChallengeHandler {
    FeedbackChallengeHandler(
      replies: ReplySender(processed: processed, delivery: delivery, logger: logger),
      learning: learning,
      notifyOutbox: notifyOutbox,
      now: now
    )
  }

  func open(_ tap: FeedbackTap) throws(StoreError) -> FeedbackOutcome {
    let outcome = try learning.consumeAndOpenChallenge(
      tap,
      prompt: LearningNotices.challengePrompt(for: tap),
      now: now()
    )
    if case .challengeOpened = outcome {
      notifyOutbox()
    }
    return outcome
  }

  func consumeIfOpen(
    text: String,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome? {
    let capturedNow = now()
    let target = DeliveryTarget.chat(message.chatId)
    let challenge = try await replies.perform(
      "feedback challenge lookup",
      updateId: rawUpdate.updateId,
      target: target
    ) {
      try learning.liveChallenge(ownerUserId: message.userId, chatId: message.chatId)
    }
    guard let challenge, challenge.expiresAt > capturedNow else {
      return nil
    }

    try await replies.claimUpdate(updateId: rawUpdate.updateId, target: target)
    let outcome = try await replies.perform(
      "feedback challenge consumption",
      updateId: rawUpdate.updateId,
      target: target,
      onFailure: .ack(Self.retryText)
    ) {
      try learning.consumeChallenge(id: challenge.id, payload: text, now: capturedNow)
    }

    let acknowledgement: String
    switch outcome {
    case .recorded:
      acknowledgement = Self.recordedText
    case .challengeOpened, .targetMissing, .ownerMismatch, .chatMismatch, .expired,
      .actionMismatch, .staleEpoch, .alreadyConsumed, .requiresPayloadChallenge:
      acknowledgement = Self.neutralText
    }
    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      target: target,
      text: acknowledgement
    )
  }
}

// MARK: - Owner Copy

private extension FeedbackChallengeHandler {
  static let recordedText = "Feedback recorded."
  static let neutralText = "This feedback prompt is no longer available."
  static let retryText = "I couldn't save that feedback. Please send it again."
}
