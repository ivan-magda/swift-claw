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
    let created = try env.learning.createTargets([first, second], chunks: chunks)

    // then — deleting nonce lookup or splitting the transactions loses an observable half
    #expect(created.map(\.nonce) == [first.nonce, second.nonce])
    #expect(
      try env.learning.feedbackTarget(nonce: first.nonce)?.targetId == created.first?.targetId
    )
    #expect(try env.targetCount() == 2)
    let deliveries = try env.deliveryRows()
    #expect(deliveries.count == 2)
    #expect(deliveries.last?.replyMarkup == chunks.last?.replyMarkup)
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
    _ = try env.learning.createTargets([duplicate], chunks: [])
    let fresh = env.target(nonce: "fresh", signal: .resultUseful, subject: "42")
    let chunk = env.chunk(subject: "rollback-subject", ordinal: 0, markup: nil)

    // when — there is deliberately no application duplicate precheck
    let failure: StoreError?
    do {
      _ = try env.learning.createTargets([fresh, duplicate], chunks: [chunk])
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
    _ = try env.learning.createTargets(targets, chunks: [])

    // when
    let outcomes = try zip(targets, signals).enumerated().map { offset, pair in
      try env.learning.consumeAndAppendEvent(
        env.tap(target: pair.0, signal: pair.1.0, updateId: Int64(offset + 1))
      )
    }

    // then — omitting any immediate action or double-incrementing revision breaks the sequence
    #expect(outcomes.count == signals.count)
    #expect(
      outcomes.allSatisfy { outcome in
        if case .recorded = outcome { return true }
        return false
      }
    )
    #expect(try env.feedbackRevision() == Int64(signals.count))
    #expect(try env.eventCount() == signals.count)
  }

  @Test func payloadActionsCannotConsumeOrAppendAtTapTimeAndAuditOnlyTheirSize() throws {
    // given — correction and edit targets with secret-like bytes that must never enter audit text
    let env = try FeedbackStoreEnvironment.make()
    let correction = env.target(nonce: "correction", signal: .resultCorrection, subject: "41")
    let edit = env.target(
      nonce: "edit",
      signal: .candidateEdit,
      subject: "candidate-secret",
      kind: .candidate
    )
    _ = try env.learning.createTargets([correction, edit], chunks: [])
    let correctionPayload = "owner correction SECRET-BYTES"
    let editPayload = "owner edit MORE-SECRET-BYTES"

    // when
    let first = try env.learning.consumeAndAppendEvent(
      env.tap(target: correction, signal: .resultCorrection, payload: correctionPayload)
    )
    let second = try env.learning.consumeAndAppendEvent(
      env.tap(target: edit, signal: .candidateEdit, updateId: 2, payload: editPayload)
    )

    // then — allowing rc/ce through the immediate path would consume, append, or bump revision
    #expect(first == .requiresPayloadChallenge)
    #expect(second == .requiresPayloadChallenge)
    #expect(try env.learning.feedbackTarget(nonce: correction.nonce)?.consumedAt == nil)
    #expect(try env.learning.feedbackTarget(nonce: edit.nonce)?.consumedAt == nil)
    #expect(try env.feedbackRevision() == 0)
    #expect(try env.eventCount() == 0)
    let audits = try env.feedbackAudits()
    #expect(audits.map(\.resultSize) == [correctionPayload.utf8.count, editPayload.utf8.count])
    #expect(
      audits.allSatisfy { row in
        row.action == AuditAction.learningFeedback.rawValue
      }
    )
    #expect(
      audits.allSatisfy { row in
        row.args.contains("SECRET-BYTES") == false
          && row.args.contains("MORE-SECRET-BYTES") == false
      }
    )
  }

  @Test func eachTargetCASPredicateFailsClosedWithoutConsuming() throws {
    // given — one independently invalid owner, chat, expiry, action, or epoch per fresh database
    let cases: [FeedbackFailureCase] = [.owner, .chat, .expiry, .action, .epoch]

    for failureCase in cases {
      let env = try FeedbackStoreEnvironment.make()
      let target = env.target(nonce: "predicate", signal: .resultUseful, subject: "41")
      _ = try env.learning.createTargets([target], chunks: [])
      if failureCase == .epoch {
        try env.setEpoch(2)
      }

      // when
      let outcome = try env.learning.consumeAndAppendEvent(
        env.invalidTap(target: target, failure: failureCase)
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
    _ = try env.learning.createTargets([target], chunks: [])
    let tap = env.tap(target: target, signal: .resultUseful, updateId: 7)

    // when — a fresh transport update reaches the already-consumed nonce a second time
    let first = try env.learning.consumeAndAppendEvent(tap)
    let second = try env.learning.consumeAndAppendEvent(
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

  @Test func newerSignalSupersedesTheExactPriorSubjectEvent() throws {
    // given — two independent targets for the same run subject
    let env = try FeedbackStoreEnvironment.make()
    let useful = env.target(nonce: "useful", signal: .resultUseful, subject: "41")
    let notUseful = env.target(nonce: "not-useful", signal: .resultNotUseful, subject: "41")
    _ = try env.learning.createTargets([useful, notUseful], chunks: [])

    // when
    _ = try env.learning.consumeAndAppendEvent(env.tap(target: useful, signal: .resultUseful))
    _ = try env.learning.consumeAndAppendEvent(
      env.tap(target: notUseful, signal: .resultNotUseful, updateId: 2)
    )

    // then — omitting the supersedes edge leaves two effective signals for one exact subject
    let events = try env.learning.feedbackEvents(
      jobId: env.jobId,
      epoch: LearningEpoch(1),
      subjectKind: .run,
      subjectDigest: "41"
    )
    #expect(events.map(\.revision) == [FeedbackRevision(1), FeedbackRevision(2)])
    #expect(events.last?.supersedes == events.first?.id)
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
    _ = try env.learning.createTargets([unrelated, exact], chunks: [])

    // when
    _ = try env.learning.consumeAndAppendEvent(
      env.tap(target: unrelated, signal: .candidateReject)
    )
    let afterUnrelated = try env.learning.openTrial(jobId: env.jobId)
    _ = try env.learning.consumeAndAppendEvent(
      env.tap(target: exact, signal: .candidateReject, updateId: 2)
    )

    // then — closing any open trial for the job fails the first assertion; exact joins close it
    #expect(afterUnrelated?.trialId == trial.trialId)
    #expect(try env.learning.openTrial(jobId: env.jobId) == nil)
    #expect(try env.trialCloseReason(trial.trialId) == "hard_veto")
  }

  @Test func candidateRejectionLeavesAStaleOrUnpointedTrialOpen() throws {
    // given — the candidate digest matches, but each database breaks one current-trial predicate
    for mismatch in CandidateTrialMismatch.allCases {
      let env = try FeedbackStoreEnvironment.make()
      let trial = try env.seedOpenTrial()
      try env.invalidateCurrentTrial(trial, mismatch: mismatch)
      let target = env.target(
        nonce: "stale-candidate-\(mismatch)",
        signal: .candidateReject,
        subject: trial.candidateDigest,
        kind: .candidate
      )
      _ = try env.learning.createTargets([target], chunks: [])

      // when
      let outcome = try env.learning.consumeAndAppendEvent(
        env.tap(target: target, signal: .candidateReject)
      )

      // then — dropping the base or current-pointer join would close an unrelated stale trial
      guard case .recorded = outcome else {
        Issue.record("expected the exact-subject event to remain independently recordable")
        continue
      }
      #expect(try env.learning.openTrial(jobId: env.jobId)?.trialId == trial.trialId)
      #expect(try env.feedbackRevision() == 1)
    }
  }

  @Test func exactRequiredTrialEvaluationDisputeClosesTheLiveTrial() throws {
    // given — the current trial assignment explicitly records the disputed required evaluation
    let env = try FeedbackStoreEnvironment.make()
    let trial = try env.seedOpenTrial()
    let evaluationDigest = "evaluation-required"
    try env.seedAssignment(trial: trial, evaluationDigest: evaluationDigest)
    let target = env.target(
      nonce: "evaluation-dispute",
      signal: .evaluationDispute,
      subject: evaluationDigest,
      kind: .evaluation
    )
    _ = try env.learning.createTargets([target], chunks: [])

    // when
    let outcome = try env.learning.consumeAndAppendEvent(
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
    // given — each database has an assignment whose digest or frozen generation does not match
    for mismatch in EvaluationDependencyMismatch.allCases {
      let env = try FeedbackStoreEnvironment.make()
      let trial = try env.seedOpenTrial()
      let targetDigest = "evaluation-target"
      try env.seedAssignment(
        trial: trial,
        evaluationDigest: mismatch == .digest ? "another-evaluation" : targetDigest,
        generation: mismatch == .generation ? trial.generation + 1 : trial.generation
      )
      let target = env.target(
        nonce: "mismatch-\(mismatch)",
        signal: .evaluationDispute,
        subject: targetDigest,
        kind: .evaluation
      )
      _ = try env.learning.createTargets([target], chunks: [])

      // when
      let outcome = try env.learning.consumeAndAppendEvent(
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
  case digest
  case generation
}

private enum CandidateTrialMismatch: CaseIterable {
  case base
  case currentPointer
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
  }

  struct AuditRow {
    let action: String
    let args: String
    let resultSize: Int
    let decision: String
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
    updateId: Int64 = 1,
    payload: String? = nil
  ) -> FeedbackTap {
    FeedbackTap(
      nonce: target.nonce,
      signal: signal,
      ownerUserId: target.ownerUserId,
      chatId: target.chatId,
      transportUpdateId: updateId,
      payload: payload,
      occurredAt: now
    )
  }

  func invalidTap(target: NewFeedbackTarget, failure: FeedbackFailureCase) -> FeedbackTap {
    FeedbackTap(
      nonce: target.nonce,
      signal: failure == .action ? .resultNotUseful : .resultUseful,
      ownerUserId: failure == .owner ? 43 : target.ownerUserId,
      chatId: failure == .chat ? 43 : target.chatId,
      transportUpdateId: 1,
      occurredAt: failure == .expiry ? target.expiresAt : now
    )
  }

  func setEpoch(_ epoch: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET learning_epoch = ? WHERE job_id = ?",
        arguments: [epoch, jobId]
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
          SELECT run_id, delivery_source, reply_markup FROM outbound_deliveries
          ORDER BY step_index
          """
      ).map { row in
        DeliveryRow(
          runId: row["run_id"],
          source: row["delivery_source"],
          replyMarkup: row["reply_markup"]
        )
      }
    }
  }

  func feedbackAudits() throws -> [AuditRow] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT action, args_redacted, result_size, decision FROM audit_events
          WHERE action = ? ORDER BY id
          """,
        arguments: [AuditAction.learningFeedback.rawValue]
      ).map { row in
        AuditRow(
          action: row["action"],
          args: row["args_redacted"],
          resultSize: row["result_size"],
          decision: row["decision"]
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

  func invalidateCurrentTrial(_ trial: Trial, mismatch: CandidateTrialMismatch) throws {
    try queue.write { db in
      switch mismatch {
      case .base:
        try db.execute(
          sql: "UPDATE job_learning_state SET stable_lesson_set_digest = ? WHERE job_id = ?",
          arguments: [trial.replacementDigest, jobId]
        )
      case .currentPointer:
        try db.execute(
          sql: "UPDATE job_learning_state SET open_trial_id = NULL WHERE job_id = ?",
          arguments: [jobId]
        )
      }
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
