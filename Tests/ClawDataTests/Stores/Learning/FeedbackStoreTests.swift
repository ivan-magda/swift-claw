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
    #expect(try env.trialCloseReason(trial.trialId) == ScheduledLearningStoreGRDB.hardVetoReason)
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
    // given — the immutable candidate manifest marks the exact source evaluation as required
    let env = try FeedbackStoreEnvironment.make()
    let evaluationDigest = "evaluation-required"
    let trial = try env.seedTypedOpenTrial(
      evaluationDigest: evaluationDigest,
      evaluationRequired: true,
      state: .draining
    )
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

    // then — consulting assignments or only open state leaves this source-bound trial live
    guard case .recorded = outcome else {
      Issue.record("expected an authenticated event")
      return
    }
    #expect(try env.learning.openTrial(jobId: env.jobId) == nil)
    #expect(try env.trialCloseReason(trial.trialId) == ScheduledLearningStoreGRDB.hardVetoReason)
  }

  @Test func onlyAnExactRequiredManifestEvaluationCanCloseTheTrial() throws {
    // given — exact-but-independent, substring-only, and unrelated source edges are all non-vetoes
    let cases: [(source: String, required: Bool, target: String)] = [
      ("evaluation-independent", false, "evaluation-independent"),
      ("prefix-evaluation-target-suffix", true, "evaluation-target"),
      ("another-evaluation", true, "evaluation-target"),
    ]
    for (index, testCase) in cases.enumerated() {
      let env = try FeedbackStoreEnvironment.make()
      let trial = try env.seedTypedOpenTrial(
        evaluationDigest: testCase.source,
        evaluationRequired: testCase.required,
        state: .open
      )
      let target = env.target(
        nonce: "typed-non-veto-\(index)",
        signal: .evaluationDispute,
        subject: testCase.target,
        kind: .evaluation
      )
      try env.createTargets([target], chunks: [])

      // when
      let outcome = try env.consume(
        env.tap(target: target, signal: .evaluationDispute)
      )

      // then — substring, job-wide, or evaluation-presence matching would close this trial
      guard case .recorded = outcome else {
        Issue.record("expected feedback to record despite a nonmatching trial dependency")
        continue
      }
      #expect(try env.learning.openTrial(jobId: env.jobId)?.trialId == trial.trialId)
      #expect(try env.eventCount() == 1)
      #expect(try env.feedbackRevision() == 1)
    }
  }

  @Test func evaluationDisputeRequiresEverySharedCandidateAndTrialIdentity() throws {
    // given — Task 10's shared identity gates remain mandatory after switching the dependency
    // source from trial assignments to the candidate's typed manifest.
    for mismatch in CandidateTrialMismatch.allCases {
      let env = try FeedbackStoreEnvironment.make()
      let evaluationDigest = "evaluation-shared-\(mismatch)"
      let trial = try env.seedTypedOpenTrial(
        evaluationDigest: evaluationDigest,
        evaluationRequired: true,
        state: .open
      )
      try env.introduceCandidateMismatch(mismatch, trial: trial)
      let target = env.target(
        nonce: "evaluation-shared-\(mismatch)",
        signal: .evaluationDispute,
        subject: evaluationDigest,
        kind: .evaluation
      )
      try env.createTargets([target], chunks: [])

      // when
      do {
        _ = try env.consume(env.tap(target: target, signal: .evaluationDispute))
      } catch {
        // Strict artifact corruption aborts the whole feedback transaction; a relational mismatch
        // may still record the event. Both outcomes are fail-closed for the trial.
      }

      // then — dropping any one shared predicate closes a trial whose frozen identity is corrupt.
      #expect(try env.trialState(trial.trialId) == mismatch.expectedState)
      #expect(try env.trialCloseReason(trial.trialId) == nil)
    }
  }

  @Test func evaluationDisputeRejectsAnUnreadableCandidateArtifact() throws {
    // given
    let env = try FeedbackStoreEnvironment.make()
    let evaluationDigest = "evaluation-unreadable-artifact"
    let trial = try env.seedTypedOpenTrial(
      evaluationDigest: evaluationDigest,
      evaluationRequired: true,
      state: .open
    )
    try env.corruptCandidateManifest(candidateDigest: trial.candidateDigest)
    let target = env.target(
      nonce: "evaluation-unreadable-artifact",
      signal: .evaluationDispute,
      subject: evaluationDigest,
      kind: .evaluation
    )
    try env.createTargets([target], chunks: [])

    // when / then — trusting only typed-looking substring bytes would close corrupt provenance.
    #expect(throws: StoreError.self) {
      _ = try env.consume(env.tap(target: target, signal: .evaluationDispute))
    }
    #expect(try env.trialState(trial.trialId) == .open)
    #expect(try env.trialCloseReason(trial.trialId) == nil)
  }

  @Test func evaluationDisputeRequiresTheExactTrialSideIdentity() throws {
    // given
    for mismatch in EvaluationTrialMismatch.allCases {
      let env = try FeedbackStoreEnvironment.make()
      let evaluationDigest = "evaluation-trial-\(mismatch)"
      let trial = try env.seedTypedOpenTrial(
        evaluationDigest: evaluationDigest,
        evaluationRequired: true,
        state: .open
      )
      try env.introduceTrialMismatch(mismatch, trial: trial)
      let target = env.target(
        nonce: "evaluation-trial-\(mismatch)",
        signal: .evaluationDispute,
        subject: evaluationDigest,
        kind: .evaluation
      )
      try env.createTargets([target], chunks: [])

      // when
      _ = try env.consume(env.tap(target: target, signal: .evaluationDispute))

      // then — a candidate manifest cannot authorize a differently bound trial row.
      #expect(try env.trialState(trial.trialId) == .open)
      #expect(try env.trialCloseReason(trial.trialId) == nil)
    }
  }

  @Test func newerSameSubjectPromptSupersedesAndEnqueuesIndependently() throws {
    // given — two independently authenticated correction targets for the same exact run
    let env = try FeedbackStoreEnvironment.make()
    let firstTarget = env.target(nonce: "prompt-one", signal: .resultCorrection, subject: "41")
    let secondTarget = env.target(nonce: "prompt-two", signal: .resultCorrection, subject: "41")
    let reviewNotice = env.chunk(subject: "41", ordinal: 0, markup: nil)
    try env.createTargets([firstTarget, secondTarget], chunks: [reviewNotice])

    // when
    let first = try env.openChallenge(firstTarget)
    let second = try env.openChallenge(secondTarget, updateId: 2)

    // then — subject-only outbox identity would drop the second prompt
    guard case .challengeOpened(let firstChallenge) = first,
      case .challengeOpened(let secondChallenge) = second
    else {
      Issue.record("expected both correction prompts to open")
      return
    }
    #expect(try env.learning.liveChallenge(ownerUserId: 42, chatId: 42)?.id == secondChallenge.id)
    #expect(try env.challenge(firstChallenge.id)?.supersededBy == secondChallenge.id)
    #expect(try env.challenge(firstChallenge.id)?.consumedAt == nil)
    #expect(
      try env.learning.consumeChallenge(
        id: firstChallenge.id,
        payload: "must not attach",
        now: env.now
      ) == .alreadyConsumed
    )
    #expect(try env.deliveryRows().count == 3)
    #expect(Set(try env.deliveryRows().map(\.deliveryKey)).count == 3)
    #expect(try env.eventCount() == 0)
    #expect(try env.feedbackRevision() == 0)
    let exposed =
      try env.deliveryRows().map { row in
        [row.deliveryKey, row.payload, row.replyMarkup ?? ""].joined()
      }.joined() + env.feedbackAudits().map(\.args).joined()
    #expect(exposed.contains(firstTarget.nonce) == false)
    #expect(exposed.contains(secondTarget.nonce) == false)
  }

  @Test func challengeReplyStoresExactUTF8AndSupersedesTheExactSubject() throws {
    // given — a prior signal on the same run and an interleaved signal on another run
    let env = try FeedbackStoreEnvironment.make()
    let prior = env.target(nonce: "prior", signal: .resultNotUseful, subject: "41")
    let other = env.target(nonce: "other-run", signal: .resultUseful, subject: "42")
    let correction = env.target(nonce: "correction", signal: .resultCorrection, subject: "41")
    try env.createTargets([prior, other, correction], chunks: [])
    _ = try env.consume(env.tap(target: prior, signal: .resultNotUseful))
    _ = try env.consume(env.tap(target: other, signal: .resultUseful, updateId: 2))
    let opened = try env.openChallenge(correction, updateId: 3)
    guard case .challengeOpened(let challenge) = opened else {
      Issue.record("expected the correction prompt to open")
      return
    }
    let payload = "Café 🚨"

    // when
    let outcome = try env.learning.consumeChallenge(
      id: challenge.id,
      payload: payload,
      now: env.now
    )

    // then — grapheme count, transport id propagation, or job-only supersession all fail here
    guard case .recorded(let event) = outcome else {
      Issue.record("expected the correction event to record")
      return
    }
    let exact = try env.feedbackEvents(
      jobId: env.jobId,
      epoch: env.state.epoch,
      subjectKind: .run,
      subjectDigest: "41"
    )
    #expect(event.payload == payload)
    #expect(event.transportUpdateId == nil)
    #expect(event.signal == .resultCorrection)
    #expect(event.supersedes == exact.first?.id)
    #expect(
      try env.feedbackEvents(
        jobId: env.jobId,
        epoch: env.state.epoch,
        subjectKind: .run,
        subjectDigest: "42"
      ).first?.supersedes == nil
    )
    let audit = try #require(try env.feedbackAudits().last)
    #expect(audit.resultSize == payload.utf8.count)
    #expect(audit.args == "subject_kind=run,subject_digest=41")
    #expect([audit.args, audit.tool, audit.decision].joined().contains(payload) == false)
    #expect(try env.deliveryRows().allSatisfy { $0.payload.contains(payload) == false })
  }

  @Test func challengeSubjectKindsMapToOnlyTheirLegalSignals() throws {
    // given — v11 has no signal column; subject kind is the closed discriminator
    let cases: [(FeedbackSubjectKind, OwnerSignal)] = [
      (.run, .resultCorrection), (.candidate, .candidateEdit),
    ]

    for (offset, entry) in cases.enumerated() {
      let env = try FeedbackStoreEnvironment.make()
      let target = env.target(
        nonce: "kind-\(offset)",
        signal: entry.1,
        subject: "subject-\(offset)",
        kind: entry.0
      )
      try env.createTargets([target], chunks: [])
      guard case .challengeOpened(let challenge) = try env.openChallenge(target) else {
        Issue.record("expected a payload challenge")
        continue
      }
      #expect(try env.eventCount() == 0)
      #expect(try env.feedbackRevision() == 0)

      // when
      let outcome = try env.learning.consumeChallenge(
        id: challenge.id,
        payload: "edit",
        now: env.now
      )

      // then — guessing one signal for both subject kinds makes one case fail
      guard case .recorded(let event) = outcome else {
        Issue.record("expected a payload event")
        continue
      }
      #expect(event.signal == entry.1)
    }
  }

  @Test func mismatchedChallengeTargetAndActionFailClosed() throws {
    // given — a corrupted target says candidate while allowing the run-only correction action
    let env = try FeedbackStoreEnvironment.make()
    let target = env.target(nonce: "mismatched-pair", signal: .resultCorrection, subject: "41")
    try env.createTargets([target], chunks: [])
    try env.setTargetSubjectKind(nonce: target.nonce, kind: .candidate)

    // when
    let outcome = try env.learning.consumeAndOpenChallenge(
      env.tap(target: target, signal: .resultCorrection),
      prompt: env.challengePrompt(target),
      now: env.now
    )

    // then — opensFeedbackChallenge alone would consume the target and create an ambiguous row
    #expect(outcome == .actionMismatch)
    #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == nil)
    #expect(try env.rowCount(table: "feedback_challenges") == 0)
  }

  @Test func unsupportedDurableChallengeKindFailsClosedOnRead() throws {
    // given — v11 can physically hold a kind with no payload signal mapping
    let env = try FeedbackStoreEnvironment.make()
    try env.insertChallengeDirectly(kind: .evaluation)

    // when / then — guessing a signal for the row would return it as actionable
    #expect(throws: StoreError.self) {
      _ = try env.learning.liveChallenge(ownerUserId: 42, chatId: 42)
    }
    #expect(try env.eventCount() == 0)
  }

  @Test func challengeCASRejectsReplayExpiryAndStaleEpoch() throws {
    // given — each case reaches an independent predicate on a fresh live challenge
    for failure in ChallengeFailure.allCases {
      let env = try FeedbackStoreEnvironment.make()
      let expiry = failure == .expired ? env.now.addingTimeInterval(1) : nil
      let target = env.target(
        nonce: "failure-\(failure)",
        signal: .resultCorrection,
        subject: "41",
        expiresAt: expiry
      )
      try env.createTargets([target], chunks: [])
      guard case .challengeOpened(let challenge) = try env.openChallenge(target) else {
        Issue.record("expected the challenge to open")
        continue
      }
      if failure == .staleEpoch {
        try env.setEpoch(2)
      }
      if failure == .replay {
        _ = try env.learning.consumeChallenge(id: challenge.id, payload: "first", now: env.now)
      }

      // when
      let outcome = try env.learning.consumeChallenge(
        id: challenge.id,
        payload: "second",
        now: failure == .expired ? target.expiresAt : env.now
      )

      // then — deleting this case's CAS predicate would append another event and revision
      #expect(outcome == failure.outcome)
      #expect(try env.eventCount() == (failure == .replay ? 1 : 0))
      #expect(try env.feedbackRevision() == (failure == .replay ? 1 : 0))
    }
  }

  @Test func promptCollisionRollsBackTargetConsumptionAndChallenge() throws {
    // given — the second prompt identity exists, so the first insert precedes the collision
    let env = try FeedbackStoreEnvironment.make()
    let target = env.target(nonce: "prompt-collision", signal: .resultCorrection, subject: "41")
    try env.createTargets([target], chunks: [])
    let first = try #require(env.challengePrompt(target).first)
    let secondPayload = "Second prompt chunk."
    let second = LearningNoticeChunk(
      subjectDigest: first.subjectDigest,
      ordinal: 1,
      chatId: first.chatId,
      payload: secondPayload,
      payloadHash: ContentHash.fnv1a(secondPayload)
    )
    let prompt = [first, second]
    try env.createTargets([], chunks: [second])

    // when / then — accepting INSERT OR IGNORE would consume a target with no new prompt
    #expect(throws: StoreError.self) {
      _ = try env.learning.consumeAndOpenChallenge(
        env.tap(target: target, signal: .resultCorrection),
        prompt: prompt,
        now: env.now
      )
    }
    #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == nil)
    #expect(try env.rowCount(table: "feedback_challenges") == 0)
    #expect(try env.deliveryRows().count == 1)
    #expect(try env.deliveryRows().first?.payload == secondPayload)
  }

  @Test func challengeAuditFailureRollsBackPayloadEventAndRevision() throws {
    // given — a live challenge and a database failure at the transaction's final audit row
    let env = try FeedbackStoreEnvironment.make()
    let target = env.target(nonce: "audit-payload", signal: .resultCorrection, subject: "41")
    try env.createTargets([target], chunks: [])
    guard case .challengeOpened(let challenge) = try env.openChallenge(target) else {
      Issue.record("expected the challenge to open")
      return
    }
    try env.forceFeedbackAuditFailure()

    // when / then — moving audit out of the transaction would leave all prior mutations behind
    #expect(throws: StoreError.self) {
      _ = try env.learning.consumeChallenge(id: challenge.id, payload: "private", now: env.now)
    }
    #expect(try env.learning.liveChallenge(ownerUserId: 42, chatId: 42)?.id == challenge.id)
    #expect(try env.eventCount() == 0)
    #expect(try env.feedbackRevision() == 0)
  }

  @Test func liveChallengePartialUniqueIndexMapsAndRollsBackDirectSQL() throws {
    // given — one mapped transaction inserts two physically live rows for the same owner DM
    let env = try FeedbackStoreEnvironment.make()

    // when
    let failure: StoreError?
    do {
      try env.insertTwoLiveChallengesDirectly()
      failure = nil
    } catch let error {
      failure = error
    }

    // then — application supersession cannot make this pass; the v11 partial index must fire
    guard case .unexpected = failure else {
      Issue.record("expected the mapped live-challenge unique-index failure")
      return
    }
    #expect(try env.rowCount(table: "feedback_challenges") == 0)
  }
}

private enum ChallengeFailure: CaseIterable {
  case replay
  case expired
  case staleEpoch

  var outcome: FeedbackOutcome {
    switch self {
    case .replay: .alreadyConsumed
    case .expired: .expired
    case .staleEpoch: .staleEpoch
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

private enum EvaluationTrialMismatch: CaseIterable {
  case job
  case epoch
  case base
  case algorithm
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
    let deliveryKey: String
    let runId: Int64?
    let source: String
    let payload: String
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
    kind: FeedbackSubjectKind = .run,
    expiresAt: Date? = nil
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
      expiresAt: expiresAt ?? now.addingTimeInterval(3_600)
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

  func challengePrompt(_ target: NewFeedbackTarget) -> [LearningNoticeChunk] {
    let payload = "Reply with the correction."
    return [
      LearningNoticeChunk(
        subjectDigest: FeedbackChallengeDeliveryIdentity.digest(targetNonce: target.nonce),
        ordinal: 0,
        chatId: target.chatId,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload)
      )
    ]
  }

  func openChallenge(
    _ target: NewFeedbackTarget,
    updateId: Int64 = 1
  ) throws(StoreError) -> FeedbackOutcome {
    try learning.consumeAndOpenChallenge(
      tap(target: target, signal: target.allowedActions[0], updateId: updateId),
      prompt: challengePrompt(target),
      now: now
    )
  }

  func challenge(_ id: Int64) throws -> FeedbackChallenge? {
    try queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM feedback_challenges WHERE challenge_id = ?",
          arguments: [id]
        )
      else {
        return nil
      }
      guard
        let kind = FeedbackSubjectKind(rawValue: row["subject_kind"]),
        let expiresAt = EpochSecondCodec.date(fromEpoch: row["expires_at"])
      else {
        throw StoreError.unexpected("challenge fixture row is unreadable")
      }
      let consumedEpoch: Int64? = row["consumed_at"]
      return FeedbackChallenge(
        id: row["challenge_id"],
        ownerUserId: row["owner_user_id"],
        chatId: row["chat_id"],
        jobId: row["job_id"],
        epoch: LearningEpoch(row["learning_epoch"]),
        subjectKind: kind,
        subjectDigest: row["subject_digest"],
        supersededBy: row["superseded_by"],
        consumedAt: consumedEpoch.flatMap(EpochSecondCodec.date(fromEpoch:)),
        expiresAt: expiresAt
      )
    }
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
          SELECT dedup_key, run_id, delivery_source, payload, reply_markup, created_ts
          FROM outbound_deliveries
          ORDER BY step_index
          """
      ).map { row in
        let createdAt: Date = row["created_ts"]
        return DeliveryRow(
          deliveryKey: row["dedup_key"],
          runId: row["run_id"],
          source: row["delivery_source"],
          payload: row["payload"],
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

  func insertTwoLiveChallengesDirectly() throws(StoreError) {
    try learning.database.writeMapping { db in
      for subject in ["41", "42"] {
        try db.execute(
          sql: """
            INSERT INTO feedback_challenges(owner_user_id, chat_id, job_id, learning_epoch,
              subject_kind, subject_digest, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            42, 42, jobId, state.epoch.value, FeedbackSubjectKind.run.rawValue, subject,
            EpochSecondCodec.epoch(now.addingTimeInterval(3_600)),
          ]
        )
      }
    }
  }

  func insertChallengeDirectly(kind: FeedbackSubjectKind) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO feedback_challenges(owner_user_id, chat_id, job_id, learning_epoch,
            subject_kind, subject_digest, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          42, 42, jobId, state.epoch.value, kind.rawValue, "unsupported",
          EpochSecondCodec.epoch(now.addingTimeInterval(3_600)),
        ]
      )
    }
  }

  func setTargetSubjectKind(nonce: String, kind: FeedbackSubjectKind) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE feedback_targets SET subject_kind = ? WHERE nonce = ?",
        arguments: [kind.rawValue, nonce]
      )
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

  func seedTypedOpenTrial(
    evaluationDigest: String,
    evaluationRequired: Bool,
    state trialState: LearningTrialState
  ) throws -> Trial {
    let replacement = try LessonSet.canonical(
      jobId: jobId,
      lessons: ["Prefer exact typed evidence."]
    )
    let evaluation = EvaluationDigest(rawValue: evaluationDigest)
    let evidence = CandidateEvidenceSource(
      runId: 91,
      digest: EvidenceDigest(rawValue: "evidence-91"),
      evaluationDigest: evaluation,
      evaluationRequired: evaluationRequired
    )
    let manifest = CandidateSourceManifest(
      origin: .reflection,
      algorithm: .v1,
      jobId: jobId,
      epoch: state.epoch,
      triggerDigest: TriggerDigest(rawValue: "typed-feedback-trigger"),
      triggerReason: .recurringIssue,
      qualifyingIssueCodes: ["typed.feedback"],
      operationId: LearningOperationID(rawValue: "typed-feedback-operation"),
      carrierDigest: CarrierDigest(rawValue: "typed-feedback-carrier"),
      resultDigest: ReflectionResultDigest(rawValue: "typed-feedback-result"),
      baseDigest: state.stableDigest,
      baseRevision: state.stableRevision,
      feedbackRevision: state.feedbackRevision,
      evidence: [evidence],
      evaluations: [CandidateEvaluationSource(runId: evidence.runId, digest: evaluation)],
      feedback: [],
      predecessorCandidate: nil,
      predecessorFeedback: nil
    )
    let artifact = try CandidateArtifact(replacement: replacement, manifest: manifest)
    let generation = 3
    return try queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(
        db,
        artifact: artifact,
        now: now
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
          artifact.digest.rawValue,
          generation,
          EpochSecondCodec.epoch(now),
          EpochSecondCodec.epoch(now.addingTimeInterval(30 * 86_400)),
          EpochSecondCodec.epoch(now.addingTimeInterval(37 * 86_400)),
          EpochSecondCodec.epoch(now),
          trialState.rawValue,
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
        candidateDigest: artifact.digest.rawValue,
        replacementDigest: replacement.digest.rawValue,
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

  func corruptCandidateManifest(candidateDigest: String) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE learning_candidates SET source_manifest = '{}' WHERE candidate_digest = ?",
        arguments: [candidateDigest]
      )
    }
  }

  func introduceTrialMismatch(_ mismatch: EvaluationTrialMismatch, trial: Trial) throws {
    let column: String
    let value: any DatabaseValueConvertible
    switch mismatch {
    case .job:
      column = "job_id"
      value = jobId + 1_000
    case .epoch:
      column = "learning_epoch"
      value = state.epoch.value + 1
    case .base:
      column = "base_digest"
      value = trial.replacementDigest
    case .algorithm:
      column = "algorithm"
      value = "stale-algorithm"
    }
    try queue.write { db in
      try db.execute(
        sql: "UPDATE learning_trials SET \(column) = ? WHERE trial_id = ?",
        arguments: [value, trial.trialId]
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
