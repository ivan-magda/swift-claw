import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct PromotionReplyTests {
  @Test func exactCurrentTargetAndFinalChunkCommitTogether() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    _ = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let promotion = try env.promoteTrial()
    let target = env.promotionReplyTarget(promotion)
    let chunks = env.promotionReplyChunks(target)

    // when
    let first = try env.learning.commitPromotionReply(
      updateId: 950,
      target: target,
      chunks: chunks,
      now: env.now
    )
    let replay = try env.learning.commitPromotionReply(
      updateId: 950,
      target: target,
      chunks: chunks,
      now: env.now
    )

    // then
    #expect(first == .committed)
    #expect(replay == .duplicate)
    let stored = try #require(try env.learning.feedbackTarget(nonce: target.nonce))
    #expect(stored.subjectKind == .promotion)
    #expect(stored.subjectDigest == promotion.promotionSubject)
    let markup = try env.queue.read { db in
      try Row.fetchAll(
        db,
        sql:
          "SELECT reply_markup FROM outbound_deliveries WHERE dedup_key IN (?, ?) ORDER BY step_index",
        arguments: StatementArguments(
          chunks.map { chunk in
            OutboxDedupKey.make(subjectDigest: chunk.subjectDigest, ordinal: chunk.ordinal)
          }
        )
      )
    }
    #expect(markup.count == chunks.count)
    #expect(
      markup.dropLast().allSatisfy { row in
        (row["reply_markup"] as String?) == nil
      }
    )
    #expect((markup.last?["reply_markup"] as String?) == chunks.last?.replyMarkup)
  }

  @Test func stalePromotionExposesNoTarget() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    _ = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let promotion = try env.promoteTrial()
    let target = env.promotionReplyTarget(promotion)
    _ = try env.learning.rollback(
      .safety(
        promotionId: promotion.decisionId,
        receiptDigest: SHA256Digest.hex("bad"),
        failure: .security
      ),
      now: env.now
    )

    // when
    let outcome = try env.learning.commitPromotionReply(
      updateId: 951,
      target: target,
      chunks: env.promotionReplyChunks(target),
      now: env.now
    )

    // then
    #expect(outcome == .stale)
    #expect(try env.learning.feedbackTarget(nonce: target.nonce) == nil)
  }

  @Test func lateOutboxFailureRollsBackTargetAndUpdateClaim() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    _ = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let promotion = try env.promoteTrial()
    let target = env.promotionReplyTarget(promotion)
    let chunks = env.promotionReplyChunks(target)
    try env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_promotion_reply BEFORE INSERT ON outbound_deliveries
          WHEN NEW.step_index = 1 BEGIN SELECT RAISE(ABORT, 'outbox failure'); END
          """
      )
    }

    // when
    #expect(throws: StoreError.self) {
      try env.learning.commitPromotionReply(
        updateId: 952,
        target: target,
        chunks: chunks,
        now: env.now
      )
    }
    try env.queue.write { db in
      try db.execute(sql: "DROP TRIGGER fail_promotion_reply")
    }
    let retry = try env.learning.commitPromotionReply(
      updateId: 952,
      target: target,
      chunks: chunks,
      now: env.now
    )

    // then
    #expect(retry == .committed)
  }
}

private extension BoundRunEnvironment {
  func promotionReplyTarget(_ promotion: DecisionReceipt) -> NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: "promotion-reply",
      jobId: jobId,
      epoch: promotion.inputs.identity.epoch,
      subjectKind: .promotion,
      subjectDigest: promotion.promotionSubject,
      allowedActions: [.promotionRollback],
      ownerUserId: 42,
      chatId: 777,
      expiresAt: now.addingTimeInterval(3_600)
    )
  }

  func promotionReplyChunks(_ target: NewFeedbackTarget) -> [LearningNoticeChunk] {
    let markup = FeedbackKeyboard.markup(rows: [
      [
        FeedbackKeyboard.Button(text: "Rollback", nonce: target.nonce, action: .promotionRollback)
      ]
    ])
    return ["Current learned set", "Current promotion"].enumerated().map { index, payload in
      LearningNoticeChunk(
        subjectDigest: SHA256Digest.hex("promotion reply"),
        ordinal: index,
        chatId: 777,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload),
        replyMarkup: index == 1 ? markup : nil
      )
    }
  }
}
