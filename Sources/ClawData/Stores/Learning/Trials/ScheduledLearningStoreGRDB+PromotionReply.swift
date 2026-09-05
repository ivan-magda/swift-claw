import ClawCore
import Foundation
import GRDB

extension ScheduledLearningStoreGRDB {
  public func commitPromotionReply(
    updateId: Int64,
    target: NewFeedbackTarget,
    chunks: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError) -> PromotionReplyOutcome {
    try database.writeMapping { db in
      guard let state = try Self.readState(db, jobId: target.jobId),
        state.epoch == target.epoch,
        let promotion = try Self.currentPromotion(db, state: state),
        target.subjectKind == .promotion, target.subjectDigest == promotion.promotionSubject,
        target.allowedActions == [.promotionRollback], target.expiresAt > now,
        let job = try Self.admissionJob(db, jobId: target.jobId),
        target.chatId == job.ownerChatId
      else {
        return .stale
      }
      guard chunks.isEmpty == false else {
        throw StoreError.unexpected("promotion reply contains no chunks")
      }
      for (index, chunk) in chunks.enumerated() {
        guard chunk.ordinal == index, chunk.chatId == target.chatId,
          chunk.subjectDigest == chunks[0].subjectDigest,
          chunk.payloadHash == ContentHash.fnv1a(chunk.payload)
        else {
          throw StoreError.unexpected("promotion reply chunk binding is invalid")
        }
        if index == chunks.count - 1 {
          guard let markup = chunk.replyMarkup,
            let buttons = try? FeedbackKeyboard.parseMarkup(markup),
            buttons.count == 1, buttons[0].count == 1,
            buttons[0][0].nonce == target.nonce,
            buttons[0][0].action == .promotionRollback
          else {
            throw StoreError.unexpected("promotion reply has no exact final rollback button")
          }
        } else if chunk.replyMarkup != nil {
          throw StoreError.unexpected("promotion keyboard must be on the final reply chunk")
        }
      }
      guard try ProcessedUpdateStoreGRDB.claimUpdate(db: db, updateId: updateId, claimedAt: now)
      else {
        return .duplicate
      }
      try Self.insertTarget(db, target)
      for chunk in chunks {
        guard try OutboxStoreGRDB.insertNotice(db, chunk: chunk, now: now) else {
          throw StoreError.unexpected("promotion reply outbox identity already exists")
        }
      }
      return .committed
    }
  }
}
