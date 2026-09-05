import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

extension FeedbackStoreTests {
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
      #expect(try env.base.terminalDecisionCount() == 1)
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
    #expect(try env.base.terminalDecisionCount() == 1)
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
}
