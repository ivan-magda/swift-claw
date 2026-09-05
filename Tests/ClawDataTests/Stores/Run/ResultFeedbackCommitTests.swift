import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ResultFeedbackCommitTests {
  @Test func validResultTargetAndFinalChunkKeyboardCommitTogether() throws {
    // given — a running bound scheduled result split across two delivery chunks
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    let target = try resultTarget(env: env, runId: runId, nonce: "valid-result")
    let turn = assistantTurn(env: env, runId: runId, target: target)

    // when
    let outcome = try env.runs.commitAssistantTurn(turn, now: env.now)

    // then — moving target insertion after the terminal commit breaks their shared visibility
    #expect(outcome == .committed)
    #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.subjectDigest == String(runId))
    let deliveries = try OutboxStoreGRDB(writer: env.queue).pendingOutbound()
    #expect(deliveries.count == 2)
    #expect(deliveries.first?.replyMarkup == nil)
    #expect(deliveries.last?.replyMarkup == Self.keyboard)
    #expect(try runState(env, runId: runId) == .done)
  }

  @Test func staleMissingOrCollidingTargetKeepsPlainCompletedDelivery() throws {
    // given — each case invalidates one commit-time feedback predicate after pre-resolution
    for invalidation in ResultTargetInvalidation.allCases {
      let env = try BoundRunEnvironment.make()
      let runId = try env.runningBoundRun()
      let target = try resultTarget(env: env, runId: runId, nonce: "invalid-\(invalidation)")
      try invalidate(invalidation, target: target, env: env, runId: runId)

      // when
      let outcome = try env.runs.commitAssistantTurn(
        assistantTurn(env: env, runId: runId, target: target),
        now: env.now
      )

      // then — a feedback race never costs the owner the answer or terminal success
      #expect(outcome == .committed)
      #expect(try runState(env, runId: runId) == .done)
      let deliveries = try OutboxStoreGRDB(writer: env.queue).pendingOutbound()
      #expect(deliveries.map(\.payload) == ["first", "answer"])
      #expect(deliveries.allSatisfy { $0.replyMarkup == nil })
      let stored = try env.learning.feedbackTarget(nonce: target.nonce)
      #expect((stored != nil) == (invalidation == .nonceCollision))
    }
  }

  @Test func feedbackTargetAbortRollsBackTheWholeAssistantCommit() throws {
    // given — the target insert fails after the run transition but before the outbox chunks
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    let target = try resultTarget(env: env, runId: runId, nonce: "target-abort")
    try env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_result_target BEFORE INSERT ON feedback_targets
          BEGIN SELECT RAISE(ABORT, 'target abort'); END
          """
      )
    }

    // when / then — any split commit would leave at least one of these durable effects behind
    #expect(throws: StoreError.self) {
      _ = try env.runs.commitAssistantTurn(
        assistantTurn(env: env, runId: runId, target: target),
        now: env.now
      )
    }
    #expect(try runState(env, runId: runId) == .running)
    #expect(try rowCount(env, table: "messages", where: "role = 'assistant'") == 0)
    #expect(try rowCount(env, table: "provider_usage") == 0)
    #expect(try rowCount(env, table: "feedback_targets") == 0)
    #expect(try rowCount(env, table: "outbound_deliveries") == 0)
  }

  @Test func outboxAbortRollsBackTheFeedbackTargetAndAssistantCommit() throws {
    // given — target insertion succeeds, then the first owner-delivery insert aborts
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    let target = try resultTarget(env: env, runId: runId, nonce: "outbox-abort")
    try env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_result_outbox BEFORE INSERT ON outbound_deliveries
          BEGIN SELECT RAISE(ABORT, 'outbox abort'); END
          """
      )
    }

    // when / then — a target may never survive without the keyboard-carrying delivery
    #expect(throws: StoreError.self) {
      _ = try env.runs.commitAssistantTurn(
        assistantTurn(env: env, runId: runId, target: target),
        now: env.now
      )
    }
    #expect(try runState(env, runId: runId) == .running)
    #expect(try rowCount(env, table: "feedback_targets") == 0)
    #expect(try rowCount(env, table: "messages", where: "role = 'assistant'") == 0)
  }
}

private enum ResultTargetInvalidation: CaseIterable {
  case missingBinding
  case staleEpoch
  case missingEffectiveSet
  case nonceCollision
}

// MARK: - Fixtures

private extension ResultFeedbackCommitTests {
  static let keyboard = "result-feedback-keyboard"

  func resultTarget(
    env: BoundRunEnvironment,
    runId: Int64,
    nonce: String
  ) throws -> NewFeedbackTarget {
    let binding = try #require(try env.learning.binding(runId: runId))
    return NewFeedbackTarget(
      nonce: nonce,
      jobId: binding.jobId,
      epoch: binding.epoch,
      subjectKind: .run,
      subjectDigest: String(runId),
      allowedActions: [.resultUseful, .resultNotUseful, .resultCorrection],
      ownerUserId: 777,
      chatId: 777,
      expiresAt: binding.occurrenceAt.addingTimeInterval(EvidenceWindow.maximumAge)
    )
  }

  func assistantTurn(
    env: BoundRunEnvironment,
    runId: Int64,
    target: NewFeedbackTarget
  ) -> AssistantTurn {
    AssistantTurn(
      runId: runId,
      sessionId: env.sessionId,
      chatId: 777,
      content: "answer",
      usage: makeProviderUsage(runId: runId, sessionId: env.sessionId),
      chunks: [
        OutboxChunk(stepIndex: 0, chatId: 777, payload: "first", payloadHash: "h0"),
        OutboxChunk(
          stepIndex: 1,
          chatId: 777,
          payload: "answer",
          payloadHash: "h1",
          replyMarkup: Self.keyboard
        ),
      ],
      feedbackTarget: target
    )
  }

  func invalidate(
    _ invalidation: ResultTargetInvalidation,
    target: NewFeedbackTarget,
    env: BoundRunEnvironment,
    runId: Int64
  ) throws {
    switch invalidation {
    case .missingBinding:
      try env.queue.write { db in
        try db.execute(
          sql: "DELETE FROM run_learning_bindings WHERE run_id = ?",
          arguments: [runId]
        )
      }
    case .staleEpoch:
      try env.queue.write { db in
        try db.execute(
          sql: "UPDATE job_learning_state SET learning_epoch = learning_epoch + 1 WHERE job_id = ?",
          arguments: [env.jobId]
        )
      }
    case .missingEffectiveSet:
      let binding = try #require(try env.learning.binding(runId: runId))
      try env.queue.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA foreign_keys = OFF")
        defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
        try db.execute(
          sql: "DELETE FROM lesson_sets WHERE job_id = ? AND digest = ?",
          arguments: [binding.jobId, binding.effectiveDigest.rawValue]
        )
      }
    case .nonceCollision:
      try env.learning.createTargets([target], chunks: [], now: env.now)
    }
  }

  func runState(_ env: BoundRunEnvironment, runId: Int64) throws -> RunState? {
    try env.queue.read { db in
      let raw = try String.fetchOne(
        db,
        sql: "SELECT state FROM runs WHERE id = ?",
        arguments: [runId]
      )
      return raw.flatMap(RunState.init(rawValue:))
    }
  }

  func rowCount(
    _ env: BoundRunEnvironment,
    table: String,
    where predicate: String = "1 = 1"
  ) throws -> Int {
    try env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(predicate)") ?? -1
    }
  }
}
