import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct FeedbackStoreTests {
  @Test func challengeDeliveryIdentityIsOpaqueAndDomainSeparated() {
    // given
    let nonce = "same bytes under two identity domains"

    // when
    let challenge = FeedbackChallengeDeliveryIdentity.digest(targetNonce: nonce)
    let undomained = SHA256Digest.hex(nonce)

    // then — hashing only the nonce would couple this key to every other opaque-address hash
    #expect(challenge != undomained)
  }

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
}
