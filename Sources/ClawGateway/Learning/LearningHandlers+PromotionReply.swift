import ClawCore
import Foundation

extension LearningHandlers {
  func promotionReply(
    jobID: Int64,
    view: [JobLearningView],
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    signal: OutboxSignal
  ) async throws(RoutingHalt) -> HandleOutcome? {
    let target = DeliveryTarget.chat(message.chatID)
    let promotion = try await replies.perform(
      "current promotion",
      updateID: rawUpdate.updateID,
      target: target
    ) {
      try learning.currentPromotion(jobID: jobID)
    }
    guard let promotion,
          case .readable(let readable)? = view.first,
          readable.stableRevision == promotion.record.stableRevision,
          readable.stableLessons.digest == promotion.inputs.replacementDigest
    else {
      return nil
    }
    let nonce = OpaqueNonce.generate()
    let feedback = NewFeedbackTarget(
      nonce: nonce,
      jobID: jobID,
      epoch: promotion.inputs.identity.epoch,
      subjectKind: .promotion,
      subjectDigest: promotion.promotionSubject,
      allowedActions: [.promotionRollback],
      ownerUserID: message.userID,
      chatID: message.chatID,
      expiresAt: now().addingTimeInterval(EvidenceWindow.maximumAge)
    )
    let markup = FeedbackKeyboard.markup(rows: [
      [
        FeedbackKeyboard.Button(
          text: "Roll back promotion",
          nonce: nonce,
          action: .promotionRollback
        ),
      ],
    ])
    let safe = redactor.redact(LearningSurface.render(view, style: .detail))
    let parts = ReplySplitter.split(
      text: safe,
      limit: TelegramMessageLimits.maxPlainMessageCharacters
    )
    let subject = SHA256Digest.hex("learning-command/\(rawUpdate.updateID)")
    let chunks = parts.enumerated().map { index, text in
      LearningNoticeChunk(
        subjectDigest: subject,
        ordinal: index,
        chatID: message.chatID,
        payload: text,
        payloadHash: ContentHash.fnv1a(text),
        replyMarkup: index == parts.count - 1 ? markup : nil
      )
    }
    let outcome = try await replies.perform(
      "promotion reply",
      updateID: rawUpdate.updateID,
      target: target
    ) {
      try learning.commitPromotionReply(
        updateID: rawUpdate.updateID,
        target: feedback,
        chunks: chunks,
        now: now()
      )
    }
    switch outcome {
    case .committed:
      signal.poke()
      return .processed
    case .duplicate:
      return replies.skipDuplicate(updateID: rawUpdate.updateID)
    case .stale:
      return nil
    }
  }
}
