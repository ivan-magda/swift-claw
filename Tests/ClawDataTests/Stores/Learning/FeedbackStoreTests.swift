import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct FeedbackStoreTests {
  @Test func targetsAndRunlessChunksCommitTogetherAndLookupUsesNonce() throws {
    // given — two targets and a multipart notice whose keyboard is on the final chunk
    let env = try FeedbackStoreEnvironment.make()
    let first = env.target(
      nonce: "opaque-a",
      signal: .candidateReject,
      subject: "candidate-a",
      kind: .candidate
    )
    let second = env.target(
      nonce: "opaque-b",
      signal: .evaluationDispute,
      subject: "evaluation-b",
      kind: .evaluation
    )
    let chunks = [
      env.chunk(subject: "candidate-a", ordinal: 0, markup: nil),
      env.chunk(subject: "candidate-a", ordinal: 1, markup: "{\"inline_keyboard\":[]}"),
    ]

    // when
    try env.createTargets([first, second], chunks: chunks)

    // then — returning identifiers or splitting the transactions loses an observable half
    #expect(try env.learning.feedbackTarget(nonce: first.nonce)?.nonce == first.nonce)
    #expect(try env.learning.feedbackTarget(nonce: second.nonce)?.nonce == second.nonce)
    #expect(try env.targetCount() == 2)
    let deliveries = try env.deliveryRows()
    #expect(deliveries.count == 2)
    #expect(deliveries.last?.replyMarkup == chunks.last?.replyMarkup)
    #expect(
      deliveries.allSatisfy { row in
        row.createdAt == env.now
      }
    )
    #expect(
      deliveries.allSatisfy { row in
        row.runId == nil && row.source == DeliverySource.learning.rawValue
      }
    )
  }

  @Test func duplicateNonceReachesTheUniqueIndexAndRollsBackTargetsAndChunks() throws {
    // given — an existing nonce plus a transaction that inserts a chunk and a fresh target first
    let env = try FeedbackStoreEnvironment.make()
    let duplicate = env.target(nonce: "duplicate", signal: .resultUseful, subject: "41")
    try env.createTargets([duplicate], chunks: [])
    let fresh = env.target(nonce: "fresh", signal: .resultUseful, subject: "42")
    let chunk = env.chunk(subject: "rollback-subject", ordinal: 0, markup: nil)

    // when — there is deliberately no application duplicate precheck
    let failure: StoreError?
    do {
      try env.createTargets([fresh, duplicate], chunks: [chunk])
      failure = nil
    } catch let error {
      failure = error
    }

    // then — the SQLite constraint is mapped and the whole write is rolled back
    guard case .unexpected(let detail) = failure else {
      Issue.record("expected a mapped UNIQUE-constraint failure")
      return
    }
    #expect(detail.contains("UNIQUE constraint failed: feedback_targets.nonce"))
    #expect(try env.targetCount() == 1)
    #expect(try env.learning.feedbackTarget(nonce: fresh.nonce) == nil)
    #expect(try env.deliveryRows().isEmpty)
  }

  @Test func everyImmediateSignalConsumesAndAdvancesOneRevision() throws {
    // given — all seven actions whose semantic event exists at tap time
    let env = try FeedbackStoreEnvironment.make()
    let signals: [(OwnerSignal, FeedbackSubjectKind)] = [
      (.resultUseful, .run),
      (.resultNotUseful, .run),
      (.evaluationConfirm, .evaluation),
      (.evaluationDispute, .evaluation),
      (.candidateApprove, .candidate),
      (.candidateReject, .candidate),
      (.promotionRollback, .promotion),
    ]
    let targets = signals.enumerated().map { offset, entry in
      env.target(
        nonce: "immediate-\(offset)",
        signal: entry.0,
        subject: "subject-\(offset)",
        kind: entry.1
      )
    }
    try env.createTargets(targets, chunks: [])

    // when
    let outcomes = try zip(targets, signals).enumerated().map { offset, pair in
      try env.consume(
        env.tap(target: pair.0, signal: pair.1.0, updateId: Int64(offset + 1))
      )
    }

    // then — hard-coding a signal or double-incrementing revision breaks the typed sequence
    #expect(outcomes.count == signals.count)
    #expect(
      outcomes.allSatisfy { outcome in
        if case .recorded = outcome { return true }
        return false
      }
    )
    #expect(try env.feedbackRevision() == Int64(signals.count))
    #expect(try env.eventCount() == signals.count)
    let events = try env.allFeedbackEvents()
    #expect(events.map(\.signal) == signals.map(\.0))
    #expect(events.map(\.revision) == (1...7).map { FeedbackRevision(Int64($0)) })
    #expect(
      events.allSatisfy { event in
        event.payload == nil && event.occurredAt == env.now
      }
    )
    for target in targets {
      #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == env.now)
    }
    let audits = try env.feedbackAudits()
    #expect(audits.count == signals.count)
    #expect(
      audits.allSatisfy { row in
        row.action == AuditAction.learningFeedback.rawValue
      }
    )
    #expect(
      audits.map(\.tool)
        == signals.map { signal, _ in
          signal.rawValue
        }
    )
    #expect(
      audits.allSatisfy { row in
        row.actor == .owner
          && row.decision == "recorded"
          && row.resultSize == 0
          && row.ts == env.now
      }
    )
    #expect(
      zip(audits, targets).allSatisfy { audit, target in
        audit.args.contains(target.subjectKind.rawValue)
          && audit.args.contains(target.subjectDigest)
          && audit.args.contains(target.nonce) == false
      }
    )
  }

  @Test func challengeActionsCannotConsumeOrAppendAnImmediateEvent() throws {
    // given — correction and edit targets; FeedbackTap structurally has no text payload
    let env = try FeedbackStoreEnvironment.make()
    let correction = env.target(nonce: "correction", signal: .resultCorrection, subject: "41")
    let edit = env.target(
      nonce: "edit",
      signal: .candidateEdit,
      subject: "candidate-secret",
      kind: .candidate
    )
    try env.createTargets([correction, edit], chunks: [])

    // when
    let first = try env.consume(
      env.tap(target: correction, signal: .resultCorrection)
    )
    let second = try env.consume(
      env.tap(target: edit, signal: .candidateEdit, updateId: 2)
    )

    // then — allowing rc/ce through the immediate path would consume, append, or bump revision
    #expect(first == .requiresPayloadChallenge)
    #expect(second == .requiresPayloadChallenge)
    #expect(try env.learning.feedbackTarget(nonce: correction.nonce)?.consumedAt == nil)
    #expect(try env.learning.feedbackTarget(nonce: edit.nonce)?.consumedAt == nil)
    #expect(try env.feedbackRevision() == 0)
    #expect(try env.eventCount() == 0)
    let audits = try env.feedbackAudits()
    #expect(audits.map(\.resultSize) == [0, 0])
    #expect(
      audits.allSatisfy { row in
        row.action == AuditAction.learningFeedback.rawValue
      }
    )
  }

  @Test func eachTargetCASPredicateFailsClosedWithoutConsuming() throws {
    // given — one independently invalid owner, chat, expiry, action, or epoch per fresh database
    let cases: [FeedbackFailureCase] = [.owner, .chat, .expiry, .action, .epoch]

    for failureCase in cases {
      let env = try FeedbackStoreEnvironment.make()
      let target = env.target(nonce: "predicate", signal: .resultUseful, subject: "41")
      try env.createTargets([target], chunks: [])
      if failureCase == .epoch {
        try env.setEpoch(2)
      }

      // when
      let outcome = try env.consume(
        env.invalidTap(target: target, failure: failureCase),
        now: failureCase == .expiry ? target.expiresAt : env.now
      )

      // then — dropping this case's SQL predicate would append an event and consume the nonce
      #expect(outcome == failureCase.outcome)
      #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == nil)
      #expect(try env.eventCount() == 0)
      #expect(try env.feedbackRevision() == 0)
      #expect(try env.feedbackAudits().last?.decision == failureCase.decision)
    }
  }

  @Test func consumedNonceCannotReplayAndRevisionAdvancesExactlyOnce() throws {
    // given
    let env = try FeedbackStoreEnvironment.make()
    let target = env.target(nonce: "single-use", signal: .resultUseful, subject: "41")
    try env.createTargets([target], chunks: [])
    let tap = env.tap(target: target, signal: .resultUseful, updateId: 7)

    // when — a fresh transport update reaches the already-consumed nonce a second time
    let first = try env.consume(tap)
    let second = try env.consume(
      env.tap(target: target, signal: .resultUseful, updateId: 8)
    )

    // then — dropping `consumed_at IS NULL` would append twice and double-increment the revision
    guard case .recorded(let event) = first else {
      Issue.record("expected the first tap to record")
      return
    }
    #expect(event.transportUpdateId == tap.transportUpdateId)
    #expect(second == .alreadyConsumed)
    #expect(try env.eventCount() == 1)
    #expect(try env.feedbackRevision() == 1)
  }

  @Test func auditFailureRollsBackConsumptionEventAndRevision() throws {
    // given — a valid target and a database-level failure at the transaction's final audit insert
    let env = try FeedbackStoreEnvironment.make()
    let target = env.target(nonce: "audit-rollback", signal: .resultUseful, subject: "41")
    try env.createTargets([target], chunks: [])
    try env.forceFeedbackAuditFailure()

    // when
    let failure: StoreError?
    do {
      _ = try env.consume(env.tap(target: target, signal: .resultUseful))
      failure = nil
    } catch let error {
      failure = error
    }

    // then — moving audit outside the write transaction would leave the preceding mutations behind
    #expect(failure != nil)
    #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == nil)
    #expect(try env.eventCount() == 0)
    #expect(try env.feedbackRevision() == 0)
  }

  @Test func newerSignalSupersedesTheExactPriorSubjectEvent() throws {
    // given — two targets for one run subject and an interleaved second subject
    let env = try FeedbackStoreEnvironment.make()
    let useful = env.target(nonce: "useful", signal: .resultUseful, subject: "41")
    let notUseful = env.target(nonce: "not-useful", signal: .resultNotUseful, subject: "41")
    let other = env.target(nonce: "other", signal: .resultUseful, subject: "42")
    try env.createTargets([useful, other, notUseful], chunks: [])

    // when
    _ = try env.consume(env.tap(target: useful, signal: .resultUseful))
    _ = try env.consume(env.tap(target: other, signal: .resultUseful, updateId: 2))
    _ = try env.consume(
      env.tap(target: notUseful, signal: .resultNotUseful, updateId: 3)
    )

    // then — omitting the supersedes edge leaves two effective signals for one exact subject
    let events = try env.feedbackEvents(
      jobId: env.jobId,
      epoch: LearningEpoch(1),
      subjectKind: .run,
      subjectDigest: "41"
    )
    #expect(events.map(\.revision) == [FeedbackRevision(1), FeedbackRevision(3)])
    #expect(events.last?.supersedes == events.first?.id)
    let otherEvent = try #require(
      try env.feedbackEvents(
        jobId: env.jobId,
        epoch: LearningEpoch(1),
        subjectKind: .run,
        subjectDigest: "42"
      ).first
    )
    #expect(otherEvent.supersedes == nil)
  }

  @Test func candidateRejectionClosesOnlyTheExactMatchingLiveTrial() throws {
    // given — one open candidate trial and first a target naming another candidate
    let env = try FeedbackStoreEnvironment.make()
    let trial = try env.seedOpenTrial()
    let unrelated = env.target(
      nonce: "other-candidate",
      signal: .candidateReject,
      subject: "other-candidate",
      kind: .candidate
    )
    let exact = env.target(
      nonce: "exact-candidate",
      signal: .candidateReject,
      subject: trial.candidateDigest,
      kind: .candidate
    )
    try env.createTargets([unrelated, exact], chunks: [])

    // when
    _ = try env.consume(
      env.tap(target: unrelated, signal: .candidateReject)
    )
    let afterUnrelated = try env.learning.openTrial(jobId: env.jobId)
    _ = try env.consume(
      env.tap(target: exact, signal: .candidateReject, updateId: 2)
    )

    // then — closing any open trial for the job fails the first assertion; exact joins close it
    #expect(afterUnrelated?.trialId == trial.trialId)
    #expect(try env.learning.openTrial(jobId: env.jobId) == nil)
    #expect(try env.trialCloseReason(trial.trialId) == "hard_veto")
  }

  @Test func candidateRejectionClosesAuthoritativeLiveTrialWithStalePointer() throws {
    // given — the authoritative trial matches while its denormalized pointer is absent or stale
    for pointer in TrialPointerState.allCases {
      let env = try FeedbackStoreEnvironment.make()
      let trial = try env.seedOpenTrial()
      try env.setTrialPointer(pointer)
      let target = env.target(
        nonce: "stale-pointer-\(pointer)",
        signal: .candidateReject,
        subject: trial.candidateDigest,
        kind: .candidate
      )
      try env.createTargets([target], chunks: [])

      // when
      let outcome = try env.consume(
        env.tap(target: target, signal: .candidateReject)
      )

      // then — reintroducing the pointer as a selector would leave the authoritative trial live
      guard case .recorded = outcome else {
        Issue.record("expected the exact-subject event to record")
        continue
      }
      #expect(try env.learning.openTrial(jobId: env.jobId) == nil)
      #expect(try env.trialState(trial.trialId) == .fellBack)
      #expect(try env.feedbackRevision() == 1)
    }
  }

  @Test func candidateRejectionRequiresEveryFrozenCandidateAndTrialPredicate() throws {
    // given — one distinct mismatch for every frozen candidate/trial dependency in the selector
    for mismatch in CandidateTrialMismatch.allCases {
      let env = try FeedbackStoreEnvironment.make()
      let trial = try env.seedOpenTrial()
      try env.introduceCandidateMismatch(mismatch, trial: trial)
      let target = env.target(
        nonce: "candidate-mismatch-\(mismatch)",
        signal: .candidateReject,
        subject: trial.candidateDigest,
        kind: .candidate
      )
      try env.createTargets([target], chunks: [])

      // when
      let outcome = try env.consume(env.tap(target: target, signal: .candidateReject))

      // then — deleting this case's independent predicate would close a nonmatching trial
      guard case .recorded = outcome else {
        Issue.record("expected the authenticated event to record")
        continue
      }
      #expect(try env.trialState(trial.trialId) == mismatch.expectedState)
      #expect(try env.trialCloseReason(trial.trialId) == nil)
      #expect(try env.feedbackRevision() == 1)
    }
  }

  @Test func exactRequiredTrialEvaluationDisputeClosesTheLiveTrial() throws {
    // given — the current trial assignment explicitly records the disputed required evaluation
    let env = try FeedbackStoreEnvironment.make()
    let trial = try env.seedOpenTrial()
    let evaluationDigest = "evaluation-required"
    try env.seedAssignment(trial: trial, evaluationDigest: evaluationDigest)
    try env.setTrialPointer(.absent)
    let target = env.target(
      nonce: "evaluation-dispute",
      signal: .evaluationDispute,
      subject: evaluationDigest,
      kind: .evaluation
    )
    try env.createTargets([target], chunks: [])

    // when
    let outcome = try env.consume(
      env.tap(target: target, signal: .evaluationDispute)
    )

    // then — dropping the exact assignment dependency leaves the trial incorrectly open
    guard case .recorded = outcome else {
      Issue.record("expected an authenticated event")
      return
    }
    #expect(try env.learning.openTrial(jobId: env.jobId) == nil)
    #expect(try env.trialCloseReason(trial.trialId) == "hard_veto")
  }

  @Test func unrelatedOrStaleTrialEvaluationDependencyDoesNotCloseTheTrial() throws {
    // given — each database has one independently stale or unrelated assignment dependency
    for mismatch in EvaluationDependencyMismatch.allCases {
      let env = try FeedbackStoreEnvironment.make()
      let trial = try env.seedOpenTrial()
      let targetDigest = "evaluation-target"
      try env.seedAssignment(trial: trial, evaluationDigest: targetDigest)
      try env.introduceAssignmentMismatch(mismatch, trial: trial)
      let target = env.target(
        nonce: "mismatch-\(mismatch)",
        signal: .evaluationDispute,
        subject: targetDigest,
        kind: .evaluation
      )
      try env.createTargets([target], chunks: [])

      // when
      let outcome = try env.consume(
        env.tap(target: target, signal: .evaluationDispute)
      )

      // then — a digest substring or job-only trial close would fail this exact-dependency guard
      guard case .recorded = outcome else {
        Issue.record("expected feedback to record despite a nonmatching trial dependency")
        continue
      }
      #expect(try env.learning.openTrial(jobId: env.jobId)?.trialId == trial.trialId)
      #expect(try env.eventCount() == 1)
      #expect(try env.feedbackRevision() == 1)
    }
  }

  @Test func evaluationDisputeRequiresEverySharedCandidateAndTrialPredicate() throws {
    // given — an exact required assignment but one mismatched shared candidate/trial dependency
    for mismatch in CandidateTrialMismatch.allCases {
      let env = try FeedbackStoreEnvironment.make()
      let trial = try env.seedOpenTrial()
      let evaluationDigest = "shared-predicate-evaluation"
      try env.seedAssignment(trial: trial, evaluationDigest: evaluationDigest)
      try env.introduceCandidateMismatch(mismatch, trial: trial)
      let target = env.target(
        nonce: "evaluation-shared-\(mismatch)",
        signal: .evaluationDispute,
        subject: evaluationDigest,
        kind: .evaluation
      )
      try env.createTargets([target], chunks: [])

      // when
      let outcome = try env.consume(env.tap(target: target, signal: .evaluationDispute))

      // then — omitting this shared predicate would close an unrelated or stale trial
      guard case .recorded = outcome else {
        Issue.record("expected the authenticated event to record")
        continue
      }
      #expect(try env.trialState(trial.trialId) == mismatch.expectedState)
      #expect(try env.trialCloseReason(trial.trialId) == nil)
      #expect(try env.feedbackRevision() == 1)
    }
  }
}

private enum FeedbackFailureCase: CaseIterable {
  case owner
  case chat
  case expiry
  case action
  case epoch

  var outcome: FeedbackOutcome {
    switch self {
    case .owner: .ownerMismatch
    case .chat: .chatMismatch
    case .expiry: .expired
    case .action: .actionMismatch
    case .epoch: .staleEpoch
    }
  }

  var decision: String {
    switch self {
    case .owner: "owner_mismatch"
    case .chat: "chat_mismatch"
    case .expiry: "expired"
    case .action: "action_mismatch"
    case .epoch: "stale_epoch"
    }
  }
}

private enum EvaluationDependencyMismatch: CaseIterable {
  case job
  case epoch
  case trial
  case digest
  case generation
  case required
}

private enum CandidateTrialMismatch: CaseIterable {
  case job
  case epoch
  case candidateBase
  case stableBase
  case algorithm
  case replacement
  case currentState

  var expectedState: LearningTrialState {
    self == .currentState ? .promoted : .open
  }
}

private enum TrialPointerState: CaseIterable {
  case absent
  case stale
}

private struct FeedbackStoreEnvironment {
  struct Trial {
    let trialId: Int64
    let candidateDigest: String
    let replacementDigest: String
    let generation: Int
  }

  struct DeliveryRow {
    let runId: Int64?
    let source: String
    let replyMarkup: String?
    let createdAt: Date
  }

  struct AuditRow {
    let actor: AuditActor
    let action: String
    let tool: String
    let args: String
    let resultSize: Int
    let decision: String
    let ts: Date
  }

  struct EventRow {
    let id: Int64
    let signal: OwnerSignal
    let revision: FeedbackRevision
    let supersedes: Int64?
    let subjectDigest: String
    let payload: String?
    let occurredAt: Date
  }

  let base: BoundRunEnvironment
  let state: JobLearningState

  var queue: DatabaseQueue { base.queue }
  var learning: ScheduledLearningStoreGRDB { base.learning }
  var jobId: Int64 { base.jobId }
  var now: Date { base.now }

  static func make() throws -> FeedbackStoreEnvironment {
    let base = try BoundRunEnvironment.make()
    let state = try base.learning.armJob(jobId: base.jobId, now: base.now)
    return FeedbackStoreEnvironment(base: base, state: state)
  }

  func target(
    nonce: String,
    signal: OwnerSignal,
    subject: String,
    kind: FeedbackSubjectKind = .run
  ) -> NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: nonce,
      jobId: jobId,
      epoch: state.epoch,
      subjectKind: kind,
      subjectDigest: subject,
      allowedActions: [signal],
      ownerUserId: 42,
      chatId: 42,
      expiresAt: now.addingTimeInterval(3_600)
    )
  }

  func chunk(subject: String, ordinal: Int, markup: String?) -> LearningNoticeChunk {
    let payload = "chunk-\(ordinal)"
    return LearningNoticeChunk(
      subjectDigest: subject,
      ordinal: ordinal,
      chatId: 42,
      payload: payload,
      payloadHash: ContentHash.fnv1a(payload),
      replyMarkup: markup
    )
  }

  func tap(
    target: NewFeedbackTarget,
    signal: OwnerSignal,
    updateId: Int64 = 1
  ) -> FeedbackTap {
    FeedbackTap(
      nonce: target.nonce,
      signal: signal,
      ownerUserId: target.ownerUserId,
      chatId: target.chatId,
      transportUpdateId: updateId
    )
  }

  func invalidTap(target: NewFeedbackTarget, failure: FeedbackFailureCase) -> FeedbackTap {
    FeedbackTap(
      nonce: target.nonce,
      signal: failure == .action ? .resultNotUseful : .resultUseful,
      ownerUserId: failure == .owner ? 43 : target.ownerUserId,
      chatId: failure == .chat ? 43 : target.chatId,
      transportUpdateId: 1
    )
  }

  func createTargets(
    _ targets: [NewFeedbackTarget],
    chunks: [LearningNoticeChunk]
  ) throws(StoreError) {
    try learning.createTargets(targets, chunks: chunks, now: now)
  }

  func consume(
    _ tap: FeedbackTap,
    now: Date? = nil
  ) throws(StoreError) -> FeedbackOutcome {
    try learning.consumeAndAppendEvent(tap, now: now ?? self.now)
  }

  func feedbackEvents(
    jobId: Int64,
    epoch: LearningEpoch,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String
  ) throws -> [EventRow] {
    try readFeedbackEvents(
      whereClause: "job_id = ? AND learning_epoch = ? AND subject_kind = ? AND subject_digest = ?",
      arguments: [jobId, epoch.value, subjectKind.rawValue, subjectDigest]
    )
  }

  func allFeedbackEvents() throws -> [EventRow] {
    try readFeedbackEvents(whereClause: "1 = 1", arguments: [])
  }

  private func readFeedbackEvents(
    whereClause: String,
    arguments: StatementArguments
  ) throws -> [EventRow] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT event_id, signal, feedback_revision, supersedes, subject_digest, payload,
            occurred_at
          FROM feedback_events
          WHERE \(whereClause)
          ORDER BY feedback_revision, event_id
          """,
        arguments: arguments
      ).map { row in
        guard
          let signal = OwnerSignal(rawValue: row["signal"]),
          let occurredAt = EpochSecondCodec.date(fromEpoch: row["occurred_at"])
        else {
          throw StoreError.unexpected("feedback event fixture row is unreadable")
        }
        return EventRow(
          id: row["event_id"],
          signal: signal,
          revision: FeedbackRevision(row["feedback_revision"]),
          supersedes: row["supersedes"],
          subjectDigest: row["subject_digest"],
          payload: row["payload"],
          occurredAt: occurredAt
        )
      }
    }
  }

  func setEpoch(_ epoch: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET learning_epoch = ? WHERE job_id = ?",
        arguments: [epoch, jobId]
      )
    }
  }

  func forceFeedbackAuditFailure() throws {
    try queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_feedback_audit BEFORE INSERT ON audit_events
          WHEN NEW.action = '\(AuditAction.learningFeedback.rawValue)'
          BEGIN SELECT RAISE(ABORT, 'forced feedback audit failure'); END
          """
      )
    }
  }

  func feedbackRevision() throws -> Int64 {
    try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT feedback_revision FROM job_learning_state WHERE job_id = ?",
        arguments: [jobId]
      ) ?? -1
    }
  }

  func targetCount() throws -> Int {
    try rowCount(table: "feedback_targets")
  }

  func eventCount() throws -> Int {
    try rowCount(table: "feedback_events")
  }

  func rowCount(table: String) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
    }
  }

  func deliveryRows() throws -> [DeliveryRow] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT run_id, delivery_source, reply_markup, created_ts FROM outbound_deliveries
          ORDER BY step_index
          """
      ).map { row in
        let createdAt: Date = row["created_ts"]
        return DeliveryRow(
          runId: row["run_id"],
          source: row["delivery_source"],
          replyMarkup: row["reply_markup"],
          createdAt: createdAt
        )
      }
    }
  }

  func feedbackAudits() throws -> [AuditRow] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT ts, actor, action, tool, args_redacted, result_size, decision FROM audit_events
          WHERE action = ? ORDER BY id
          """,
        arguments: [AuditAction.learningFeedback.rawValue]
      ).map { row in
        let ts: Date = row["ts"]
        guard let actor = AuditActor(rawValue: row["actor"]) else {
          throw StoreError.unexpected("feedback audit fixture actor is unreadable")
        }
        return AuditRow(
          actor: actor,
          action: row["action"],
          tool: row["tool"],
          args: row["args_redacted"],
          resultSize: row["result_size"],
          decision: row["decision"],
          ts: ts
        )
      }
    }
  }

  func seedOpenTrial() throws -> Trial {
    let candidate = try LessonSet.canonical(jobId: jobId, lessons: ["Prefer exact evidence."])
    let candidateDigest = SHA256Digest.hex("feedback-candidate-\(jobId)")
    let generation = 3
    return try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
            created_at) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          jobId,
          candidate.digest.rawValue,
          candidate.schemaVersion,
          candidate.canonicalBytes,
          LessonSetSource.reflectorCandidate.rawValue,
          EpochSecondCodec.epoch(now),
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO learning_candidates(candidate_digest, job_id, learning_epoch,
            replacement_digest, base_digest, base_revision, frozen_feedback_revision, origin,
            source_manifest, algorithm, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          candidateDigest,
          jobId,
          state.epoch.value,
          candidate.digest.rawValue,
          state.stableDigest.rawValue,
          state.stableRevision.value,
          state.feedbackRevision.value,
          LearningPhase.reflector.rawValue,
          "{}",
          LearningAlgorithm.v1.rawValue,
          EpochSecondCodec.epoch(now),
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, 3, 0, ?, ?, ?)
          """,
        arguments: [
          jobId,
          state.epoch.value,
          state.stableDigest.rawValue,
          candidateDigest,
          generation,
          EpochSecondCodec.epoch(now),
          EpochSecondCodec.epoch(now.addingTimeInterval(30 * 86_400)),
          EpochSecondCodec.epoch(now.addingTimeInterval(37 * 86_400)),
          EpochSecondCodec.epoch(now),
          LearningTrialState.open.rawValue,
          LearningAlgorithm.v1.rawValue,
        ]
      )
      let trialId = db.lastInsertedRowID
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = ? WHERE job_id = ?",
        arguments: [trialId, jobId]
      )
      return Trial(
        trialId: trialId,
        candidateDigest: candidateDigest,
        replacementDigest: candidate.digest.rawValue,
        generation: generation
      )
    }
  }

  func setTrialPointer(_ state: TrialPointerState) throws {
    try queue.write { db in
      let pointer: Int64? = state == .absent ? nil : 999_999
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = ? WHERE job_id = ?",
        arguments: [pointer, jobId]
      )
    }
  }

  func trialState(_ trialId: Int64) throws -> LearningTrialState? {
    try queue.read { db in
      let raw = try String.fetchOne(
        db,
        sql: "SELECT state FROM learning_trials WHERE trial_id = ?",
        arguments: [trialId]
      )
      return raw.flatMap(LearningTrialState.init(rawValue:))
    }
  }

  func seedAssignment(
    trial: Trial,
    evaluationDigest: String,
    generation: Int? = nil
  ) throws {
    let fired = try base.jobs.fireNow(jobId: jobId, now: now)
    guard case .fired(let claimed) = fired else {
      throw StoreError.unexpected("trial fixture failed to create an assignment")
    }
    try queue.write { db in
      try db.execute(
        sql: """
          UPDATE trial_assignments SET evaluation_digest = ?, trial_generation = ?
          WHERE run_id = ?
          """,
        arguments: [evaluationDigest, generation ?? trial.generation, claimed.runId]
      )
    }
  }

  func introduceCandidateMismatch(_ mismatch: CandidateTrialMismatch, trial: Trial) throws {
    switch mismatch {
    case .job:
      try queue.write { db in
        let otherJobId = jobId + 1_000
        try db.execute(
          sql: """
            INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
              created_at)
            SELECT ?, digest, schema_version, canonical_bytes, source, created_at
            FROM lesson_sets WHERE job_id = ? AND digest = ?
            """,
          arguments: [otherJobId, jobId, trial.replacementDigest]
        )
        try db.execute(
          sql: "UPDATE learning_candidates SET job_id = ? WHERE candidate_digest = ?",
          arguments: [otherJobId, trial.candidateDigest]
        )
      }
    case .epoch:
      try updateCandidate(
        column: "learning_epoch",
        value: state.epoch.value + 1,
        digest: trial.candidateDigest
      )
    case .candidateBase:
      try updateCandidate(
        column: "base_digest",
        value: "stale-base",
        digest: trial.candidateDigest
      )
    case .stableBase:
      try queue.write { db in
        try db.execute(
          sql: "UPDATE job_learning_state SET stable_lesson_set_digest = ? WHERE job_id = ?",
          arguments: [trial.replacementDigest, jobId]
        )
      }
    case .algorithm:
      try updateCandidate(
        column: "algorithm",
        value: "stale-algorithm",
        digest: trial.candidateDigest
      )
    case .replacement:
      try updateWithForeignKeysDisabled(
        sql: "UPDATE learning_candidates SET replacement_digest = ? WHERE candidate_digest = ?",
        arguments: ["missing-replacement", trial.candidateDigest]
      )
    case .currentState:
      try queue.write { db in
        try db.execute(
          sql: "UPDATE learning_trials SET state = ? WHERE trial_id = ?",
          arguments: [LearningTrialState.promoted.rawValue, trial.trialId]
        )
      }
    }
  }

  func introduceAssignmentMismatch(
    _ mismatch: EvaluationDependencyMismatch,
    trial: Trial
  ) throws {
    switch mismatch {
    case .job:
      try updateAssignment(column: "job_id", value: jobId + 1, trialId: trial.trialId)
    case .epoch:
      try updateAssignment(
        column: "learning_epoch",
        value: state.epoch.value + 1,
        trialId: trial.trialId
      )
    case .trial:
      try updateWithForeignKeysDisabled(
        sql: "UPDATE trial_assignments SET trial_id = ? WHERE trial_id = ?",
        arguments: [trial.trialId + 999, trial.trialId]
      )
    case .digest:
      try updateAssignment(
        column: "evaluation_digest",
        value: "another-evaluation",
        trialId: trial.trialId
      )
    case .generation:
      try updateAssignment(
        column: "trial_generation",
        value: trial.generation + 1,
        trialId: trial.trialId
      )
    case .required:
      try updateAssignment(column: "evaluation_required", value: false, trialId: trial.trialId)
    }
  }

  private func updateCandidate(
    column: String,
    value: (any DatabaseValueConvertible)?,
    digest: String
  ) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE learning_candidates SET \(column) = ? WHERE candidate_digest = ?",
        arguments: [value, digest]
      )
    }
  }

  private func updateAssignment(
    column: String,
    value: (any DatabaseValueConvertible)?,
    trialId: Int64
  ) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE trial_assignments SET \(column) = ? WHERE trial_id = ?",
        arguments: [value, trialId]
      )
    }
  }

  private func updateWithForeignKeysDisabled(
    sql: String,
    arguments: StatementArguments
  ) throws {
    try queue.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      do {
        try db.execute(sql: sql, arguments: arguments)
        try db.execute(sql: "PRAGMA foreign_keys = ON")
      } catch {
        try? db.execute(sql: "PRAGMA foreign_keys = ON")
        throw error
      }
    }
  }

  func trialCloseReason(_ trialId: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT close_reason FROM learning_trials WHERE trial_id = ?",
        arguments: [trialId]
      )
    }
  }
}
