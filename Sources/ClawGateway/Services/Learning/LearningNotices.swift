import ClawCore
import Foundation

public enum LearningReviewError: Error, Sendable, Equatable {
  case invalidCandidate
  case nonceGenerationFailed
}

/// Deterministic owner-facing feedback controls and prompts.
public struct LearningNotices: Sendable {
  private let learning: any ScheduledLearningStore
  private let poke: @Sendable () -> Void
  private let nonceGenerator: @Sendable () -> String
  private let chunkLimit: Int

  public init(learning: any ScheduledLearningStore, signal: OutboxSignal) {
    self.init(
      learning: learning,
      poke: signal.poke,
      nonceGenerator: OpaqueNonce.generate,
      chunkLimit: ReplySplitter.limit
    )
  }

  init(
    learning: any ScheduledLearningStore,
    poke: @escaping @Sendable () -> Void,
    nonceGenerator: @escaping @Sendable () -> String,
    chunkLimit: Int
  ) {
    self.learning = learning
    self.poke = poke
    self.nonceGenerator = nonceGenerator
    self.chunkLimit = chunkLimit
  }

  public func reviewNotice(
    candidate: CandidateArtifact,
    state: CandidateReviewState,
    ownerUserId: Int64,
    chatId: Int64,
    now: Date
  ) throws -> CandidateReviewNotice {
    guard
      candidate.manifest.evaluations.count <= EvidenceWindow.maximumCount,
      Set(candidate.manifest.evaluations.map(\.digest)).count
        == candidate.manifest.evaluations.count
    else {
      throw LearningReviewError.invalidCandidate
    }
    let nonces = try distinctNonces(count: candidate.manifest.evaluations.count + 1)
    let expiry = now.addingTimeInterval(EvidenceWindow.maximumAge)
    let candidateActions: [OwnerSignal]
    switch state {
    case .admitted:
      candidateActions = [.candidateReject, .candidateEdit]
    case .awaitingApproval:
      candidateActions = [.candidateApprove, .candidateReject, .candidateEdit]
    }
    var targets = [
      NewFeedbackTarget(
        nonce: nonces[0],
        jobId: candidate.manifest.jobId,
        epoch: candidate.manifest.epoch,
        subjectKind: .candidate,
        subjectDigest: candidate.digest.rawValue,
        allowedActions: candidateActions,
        ownerUserId: ownerUserId,
        chatId: chatId,
        expiresAt: expiry
      )
    ]
    targets += candidate.manifest.evaluations.enumerated().map { index, evaluation in
      NewFeedbackTarget(
        nonce: nonces[index + 1],
        jobId: candidate.manifest.jobId,
        epoch: candidate.manifest.epoch,
        subjectKind: .evaluation,
        subjectDigest: evaluation.digest.rawValue,
        allowedActions: [.evaluationConfirm, .evaluationDispute],
        ownerUserId: ownerUserId,
        chatId: chatId,
        expiresAt: expiry
      )
    }
    let subject = CandidateReviewIdentity.digest(candidateDigest: candidate.digest)
    let parts = ReplySplitter.split(text: reviewText(candidate), limit: chunkLimit)
    guard parts.isEmpty == false else {
      throw LearningReviewError.invalidCandidate
    }
    guard
      let markup = FeedbackKeyboard.candidateReviewMarkup(
        targets: targets,
        evaluations: candidate.manifest.evaluations
      )
    else {
      throw LearningReviewError.invalidCandidate
    }
    let chunks = parts.enumerated().map { ordinal, payload in
      LearningNoticeChunk(
        subjectDigest: subject,
        ordinal: ordinal,
        chatId: chatId,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload),
        replyMarkup: ordinal == parts.count - 1 ? markup : nil
      )
    }
    return CandidateReviewNotice(
      candidateDigest: candidate.digest,
      state: state,
      subjectDigest: subject,
      targets: targets,
      chunks: chunks
    )
  }

  @discardableResult
  public func enqueueReview(
    candidate: CandidateArtifact,
    state: CandidateReviewState,
    ownerUserId: Int64,
    chatId: Int64,
    now: Date
  ) throws -> Bool {
    let review = try reviewNotice(
      candidate: candidate,
      state: state,
      ownerUserId: ownerUserId,
      chatId: chatId,
      now: now
    )
    let inserted = try learning.commitCandidateReview(review, now: now)
    if inserted {
      poke()
    }
    return inserted
  }

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
      payload = #"Reply with one JSON object: {"lessons":["..."]} (zero to three lessons)."#
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

// MARK: - Candidate Review

private extension LearningNotices {
  func distinctNonces(count: Int) throws -> [String] {
    var seen: Set<String> = []
    var nonces: [String] = []
    for _ in 0..<(count * 4) {
      let nonce = nonceGenerator()
      guard nonce.isEmpty == false else {
        continue
      }
      if seen.insert(nonce).inserted {
        nonces.append(nonce)
      }
      if nonces.count == count {
        return nonces
      }
    }
    throw LearningReviewError.nonceGenerationFailed
  }

  func reviewText(_ candidate: CandidateArtifact) -> String {
    let lessons = candidate.replacement.lessons
    let body =
      lessons.isEmpty
      ? "- Remove all learned lessons."
      : lessons.enumerated().map { index, lesson in
        "\(index + 1). \(lesson)"
      }.joined(separator: "\n")
    return "Candidate lessons for review:\n\(body)"
  }
}
