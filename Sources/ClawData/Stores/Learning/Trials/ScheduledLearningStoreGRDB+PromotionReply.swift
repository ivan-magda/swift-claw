import ClawCore
import Foundation
import GRDB

extension ScheduledLearningStoreGRDB {
  public func commitPromotionReply(
    updateID: Int64,
    target: NewFeedbackTarget,
    chunks: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError) -> PromotionReplyOutcome {
    try database.writeMapping { db in
      guard let state = try Self.readState(db, jobID: target.jobID),
            state.epoch == target.epoch,
            let promotion = try Self.currentPromotion(db, state: state),
            target.subjectKind == .promotion,
            target.subjectDigest == promotion.promotionSubject,
            target.allowedActions == [.promotionRollback],
            target.expiresAt > now,
            let job = try Self.admissionJob(db, jobID: target.jobID),
            target.chatID == job.ownerChatID
      else {
        return .stale
      }
      guard chunks.isEmpty == false else {
        throw StoreError.unexpected("promotion reply contains no chunks")
      }
      for (index, chunk) in chunks.enumerated() {
        guard chunk.ordinal == index,
              chunk.chatID == target.chatID,
              chunk.subjectDigest == chunks[0].subjectDigest,
              chunk.payloadHash == ContentHash.fnv1a(chunk.payload)
        else {
          throw StoreError.unexpected("promotion reply chunk binding is invalid")
        }
        if index == chunks.count - 1 {
          guard let markup = chunk.replyMarkup,
                let buttons = try? FeedbackKeyboard.parseMarkup(markup),
                buttons.count == 1,
                buttons[0].count == 1,
                buttons[0][0].nonce == target.nonce,
                buttons[0][0].action == .promotionRollback
          else {
            throw StoreError.unexpected("promotion reply has no exact final rollback button")
          }
        } else if chunk.replyMarkup != nil {
          throw StoreError.unexpected("promotion keyboard must be on the final reply chunk")
        }
      }
      guard try ProcessedUpdateStoreGRDB.claimUpdate(db: db, updateID: updateID, claimedAt: now)
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
