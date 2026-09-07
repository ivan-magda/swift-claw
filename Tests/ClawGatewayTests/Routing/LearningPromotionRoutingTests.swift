import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData
@testable import ClawGateway

@Suite struct LearningPromotionRoutingTests {
  @Test func currentPromotionReplyUsesOutboxAndPokesAfterCommit() async throws {
    // given
    let signal = OutboxSignal()
    let harness = try LearningRoutingTests.Harness.make(outboxSignal: signal)
    let job = try harness.createJob(label: "current promotion")
    let promotionId = try harness.seedCurrentPromotion(jobId: job.id)

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 980, from: 42, text: "/learning \(job.id)")
    )
    signal.finish()
    var notifications = signal.notifications.makeAsyncIterator()
    let poked = await notifications.next() != nil

    // then
    #expect(outcome == .processed)
    #expect(poked)
    #expect(await harness.transport.sent.isEmpty)
    let rows = try harness.queue.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT payload, reply_markup FROM outbound_deliveries ORDER BY step_index"
      )
    }
    let last = try #require(rows.last)
    let markup = try #require(last["reply_markup"] as String?)
    let button = try #require(try FeedbackKeyboard.parseMarkup(markup).first?.first)
    #expect(button.action == .promotionRollback)
    let target = try #require(try harness.learning.feedbackTarget(nonce: button.nonce))
    #expect(target.subjectDigest == String(promotionId))
    #expect(target.ownerUserId == 42)
    #expect(target.chatId == 42)
    #expect((last["payload"] as String).contains(LearningDecisionResult.stale.rawValue))
  }
}

private extension LearningRoutingTests.Harness {
  func seedCurrentPromotion(jobId: Int64) throws -> Int64 {
    let state = try learning.armJob(jobId: jobId, now: now)
    let trial = LearningTrial(
      identity: LearningTrialIdentity(trialId: 1, jobId: jobId, epoch: state.epoch, generation: 1),
      baseDigest: LessonSetDigest(rawValue: SHA256Digest.hex("retained predecessor")),
      baseRevision: StableRevision(0),
      candidateDigest: CandidateDigest(rawValue: SHA256Digest.hex("empty replacement candidate")),
      replacementDigest: state.stableDigest,
      algorithm: .v1,
      admittedAt: now,
      cohortCutoff: now,
      maxAssignments: TrialAdmissionPolicy.maximumAssignments,
      consumedAssignments: 2,
      assignmentDeadline: now.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow),
      decisionDeadline: now.addingTimeInterval(TrialAdmissionPolicy.decisionWindow),
      state: .promoted,
      hardVetoes: []
    )
    let inputs = TrialDecisionInputs(trial: trial, feedbackRevision: state.feedbackRevision)
    return try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET stable_revision = 1 WHERE job_id = ?",
        arguments: [jobId]
      )
      let promoted = LearningDecisionRecord(
        result: .promoted,
        reason: LearningDecisionResult.promoted.rawValue,
        cohort: [],
        stableRevision: StableRevision(1)
      )
      try insertDecisionProjection(db, inputs: inputs, record: promoted, kind: .trial)
      let promotionId = db.lastInsertedRowID
      let stale = LearningDecisionRecord(
        result: .stale,
        reason: LearningDecisionResult.stale.rawValue,
        cohort: [],
        stableRevision: StableRevision(1),
        rollbackTrigger: .adapter(
          promotionId: promotionId,
          adapterId: "unfrozen",
          outcome: .regression
        )
      )
      try insertDecisionProjection(db, inputs: inputs, record: stale, kind: .rollback)
      return promotionId
    }
  }

  func insertDecisionProjection(
    _ db: Database,
    inputs: TrialDecisionInputs,
    record: LearningDecisionRecord,
    kind: LearningDecisionKind
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO learning_decisions(kind, job_id, learning_epoch, inputs, result, algorithm, decided_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        kind.rawValue, inputs.identity.jobId, inputs.identity.epoch.value,
        try ScheduledLearningStoreGRDB.canonicalDecisionJSON(inputs),
        try ScheduledLearningStoreGRDB.canonicalDecisionJSON(record), LearningAlgorithm.v1.rawValue,
        EpochSecondCodec.epoch(now),
      ]
    )
  }
}
