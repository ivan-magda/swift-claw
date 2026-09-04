import ClawCore

/// Deterministic owner-facing feedback controls and prompts.
public enum LearningNotices {
  /// The three actions available on a completed scheduled result, in their fixed display order.
  public static func resultKeyboard(target: NewFeedbackTarget) -> String {
    let useful = FeedbackKeyboard.callbackData(nonce: target.nonce, action: .resultUseful)
    let notUseful = FeedbackKeyboard.callbackData(nonce: target.nonce, action: .resultNotUseful)
    let correction = FeedbackKeyboard.callbackData(nonce: target.nonce, action: .resultCorrection)
    return
      #"{"inline_keyboard":[["#
      + #"{"callback_data":"\#(useful)","text":"Useful"},"#
      + #"{"callback_data":"\#(notUseful)","text":"Not useful"},"#
      + #"{"callback_data":"\#(correction)","text":"Correct it"}"#
      + "]]}"
  }

  static func challengePrompt(for tap: FeedbackTap) -> [LearningNoticeChunk] {
    let payload: String
    switch tap.signal {
    case .resultCorrection:
      payload = "Reply with what this result should have done differently."
    case .candidateEdit:
      payload = "Reply with the edit you want to make."
    case .resultUseful, .resultNotUseful, .evaluationConfirm, .evaluationDispute,
      .candidateApprove, .candidateReject, .promotionRollback:
      payload = "Reply with your feedback."
    }
    return [
      LearningNoticeChunk(
        subjectDigest: FeedbackChallengeDeliveryIdentity.digest(targetNonce: tap.nonce),
        ordinal: 0,
        chatId: tap.chatId,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload)
      )
    ]
  }
}
