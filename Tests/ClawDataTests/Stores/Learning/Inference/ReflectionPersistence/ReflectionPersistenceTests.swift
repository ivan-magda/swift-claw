import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ReflectionPersistenceTests {
  @Test func aggregatePreparationPreservesExactOrderedTypedEdges() throws {
    // given
    let env = try BoundRunEnvironment.make()

    // when
    let fixture = try env.reflectionFixture()

    // then — replacing trigger order with a query's natural order loses the frozen source identity
    #expect(fixture.preparation.trigger == fixture.trigger)
    #expect(fixture.preparation.evidenceSources.map(\.digest) == fixture.trigger.evidenceDigests)
    #expect(fixture.preparation.evidenceSources.map(\.runId).count == 2)
    #expect(fixture.preparation.evaluationSources.map(\.runId).count == 2)
    #expect(
      fixture.preparation.evidenceSources.map(\.evaluationDigest)
        == fixture.preparation.evaluationSources.map(\.digest)
    )
    #expect(
      fixture.preparation.evidenceSources.allSatisfy { source in
        source.evaluationRequired
      }
    )
    #expect(
      fixture.preparation.evaluations.map(\.summary.outcome).allSatisfy { outcome in
        outcome == "negative"
      }
    )
    #expect(
      fixture.preparation.evaluations.map(\.summary.issueCodes).allSatisfy { codes in
        codes == ["material.missed"]
      }
    )
  }

  @Test func authorizationRechecksTheFrozenCutoff() throws {
    // given — preparation and claim happened before feedback changed
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let key = LearningOperationKey(
      jobId: env.jobId,
      epoch: fixture.trigger.epoch,
      phase: .reflector,
      sourceDigest: fixture.trigger.digest.rawValue,
      promptVersion: ReflectorPrompt.v1.version,
      schemaVersion: ReflectorOutput.currentSchemaVersion,
      rubricVersion: ReflectorRubric.v1
    )
    let claim = try env.claim(key)
    try env.advanceFeedbackRevision()
    let authorization = reflectionAuthorization(env, fixture: fixture, claim: claim)

    // when
    let outcome = try env.learning.authorizeAndStartOperation(authorization, now: env.now)

    // then — trusting the earlier aggregate read would send obsolete context after this race
    #expect(outcome == .superseded)
    #expect(try env.operationState(claim.id) == .claimed)
    #expect(try env.providerCallID(claim.id) == nil)
  }

  @Test func aggregatePreparationScansLiveTrialRowsInsteadOfTheConveniencePointer() throws {
    // given — a live trial exists while the denormalized pointer is deliberately absent
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: started)
    try env.insertLiveTrialWithoutPointer(candidate: artifact)
    #expect(try env.currentLearningState().openTrialId == nil)

    // when
    let preparation = try env.learning.prepareReflection(trigger: fixture.trigger)

    // then — consulting only open_trial_id would admit reflection during an authoritative live row
    #expect(preparation == nil)
  }

  @Test func aggregatePreparationKeepsOnlyUnsupersededFeedbackEdgesAndPayload() throws {
    // given — two corrections on one run; only the successor remains effective at revision two
    let env = try BoundRunEnvironment.make()
    let initial = try env.reflectionFixture()
    let runId = initial.preparation.evidenceSources[0].runId
    let first = try env.appendFeedback(
      subjectKind: .run,
      subjectDigest: String(runId),
      signal: .resultCorrection,
      payload: "old correction"
    )
    let second = try env.appendFeedback(
      subjectKind: .run,
      subjectDigest: String(runId),
      signal: .resultCorrection,
      payload: "new correction",
      supersedes: first.eventId
    )
    let trigger = TriggerIdentity(
      jobId: env.jobId,
      epoch: initial.trigger.epoch,
      algorithm: .v1,
      stableDigest: initial.trigger.stableDigest,
      evidenceDigests: initial.trigger.evidenceDigests,
      feedbackRevision: second.revision,
      issueCodes: initial.trigger.issueCodes,
      reason: .ownerCorrection
    )

    // when
    let prepared = try #require(try env.learning.prepareReflection(trigger: trigger))

    // then — retaining the superseded edge would bind provenance the reducer no longer consulted
    #expect(prepared.feedbackSources == [second])
    #expect(second.digest.rawValue.isEmpty == false)
    #expect(second.digest.rawValue != String(second.eventId))
    let expectedDigest = try FeedbackEventDigest.of(
      eventId: second.eventId,
      jobId: env.jobId,
      epoch: initial.trigger.epoch,
      subjectKind: .run,
      subjectDigest: String(runId),
      signal: .resultCorrection,
      payload: "new correction",
      actor: .owner,
      transportUpdateId: nil,
      revision: second.revision,
      supersedes: first.eventId,
      occurredAtEpochSecond: Int64(env.now.timeIntervalSince1970.rounded())
    )
    #expect(second.digest == expectedDigest)
    #expect(prepared.ownerPayloads.map(\.payload) == ["new correction"])
    #expect(prepared.ownerPayloads.map(\.source) == [second])
  }

  @Test func aggregatePreparationKeepsCorrectionIndependentOfDisputedEvaluation() throws {
    // given — the run correction remains usable, but may consume no disputed evaluator fields
    let env = try BoundRunEnvironment.make()
    let initial = try env.reflectionFixture()
    let first = initial.preparation.evaluations[0]
    _ = try env.appendFeedback(
      subjectKind: .evaluation,
      subjectDigest: first.evaluation.digest.rawValue,
      signal: .evaluationDispute
    )
    let correction = try env.appendFeedback(
      subjectKind: .run,
      subjectDigest: String(first.evidence.runId),
      signal: .resultCorrection,
      payload: "the output still missed the material change"
    )
    let trigger = TriggerIdentity(
      jobId: env.jobId,
      epoch: initial.trigger.epoch,
      algorithm: .v1,
      stableDigest: initial.trigger.stableDigest,
      evidenceDigests: initial.trigger.evidenceDigests,
      feedbackRevision: correction.revision,
      issueCodes: [],
      reason: .ownerCorrection
    )

    // when
    let prepared = try #require(try env.learning.prepareReflection(trigger: trigger))

    // then — vetoing every dispute would erase the separate authenticated run correction
    let corrected = try #require(
      prepared.evaluations.first { evaluation in
        evaluation.evidence.runId == first.evidence.runId
      }
    )
    #expect(corrected.evidence.evaluationRequired == false)
    #expect(corrected.summary.issueCodes.isEmpty)
    #expect(prepared.feedbackSources.count == 2)
  }

  @Test(arguments: [OwnerSignal.resultCorrection, OwnerSignal.resultNotUseful])
  func undisputedOwnerResultUsingEvaluatorCodesKeepsEvaluationDependency(
    signal: OwnerSignal
  ) throws {
    // given — both owner categories reuse the undisputed evaluator's material issue code
    let env = try BoundRunEnvironment.make()
    let initial = try env.reflectionFixture()
    let first = initial.preparation.evaluations[0]
    let result = try env.appendFeedback(
      subjectKind: .run,
      subjectDigest: String(first.evidence.runId),
      signal: signal,
      payload: signal == .resultCorrection ? "owner correction" : nil
    )
    let trigger = TriggerIdentity(
      jobId: env.jobId,
      epoch: initial.trigger.epoch,
      algorithm: .v1,
      stableDigest: initial.trigger.stableDigest,
      evidenceDigests: initial.trigger.evidenceDigests,
      feedbackRevision: result.revision,
      issueCodes: initial.trigger.issueCodes,
      reason: signal == .resultCorrection ? .ownerCorrection : .recurringIssue
    )

    // when
    let prepared = try #require(try env.learning.prepareReflection(trigger: trigger))

    // then — deriving dependency from owner-result presence alone would freeze this as independent
    let resolved = try #require(
      prepared.evaluations.first { evaluation in
        evaluation.evidence.runId == first.evidence.runId
      }
    )
    #expect(resolved.evidence.evaluationRequired)
    #expect(resolved.summary.issueCodes == initial.trigger.issueCodes)
  }

  @Test func aggregatePreparationRejectsARequiredDisputeDespiteAnotherRunsCorrection() throws {
    // given — one run depends on its disputed evaluator while another has an independent correction
    let env = try BoundRunEnvironment.make()
    let initial = try env.reflectionFixture()
    let disputed = initial.preparation.evaluations[0]
    let corrected = initial.preparation.evaluations[1]
    _ = try env.appendFeedback(
      subjectKind: .evaluation,
      subjectDigest: disputed.evaluation.digest.rawValue,
      signal: .evaluationDispute
    )
    let correction = try env.appendFeedback(
      subjectKind: .run,
      subjectDigest: String(corrected.evidence.runId),
      signal: .resultCorrection,
      payload: "the second run needs correction"
    )
    let trigger = TriggerIdentity(
      jobId: env.jobId,
      epoch: initial.trigger.epoch,
      algorithm: .v1,
      stableDigest: initial.trigger.stableDigest,
      evidenceDigests: initial.trigger.evidenceDigests,
      feedbackRevision: correction.revision,
      issueCodes: [],
      reason: .ownerCorrection
    )

    // when
    let prepared = try env.learning.prepareReflection(trigger: trigger)

    // then — applying the second run's correction as a blanket dispute waiver retains bad evidence
    #expect(prepared == nil)
  }

  @Test func aggregatePreparationExcludesEvidenceProducedUnderATrial() throws {
    // given — one qualifying source was produced under a closed trial, so no live-trial gate hides it
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: started)
    try env.markAsClosedTrialEvidence(
      runId: fixture.preparation.evidenceSources[0].runId,
      candidate: artifact
    )

    // when
    let prepared = try env.learning.prepareReflection(trigger: fixture.trigger)

    // then — accepting trial output would let candidate behavior teach the production reflector
    #expect(prepared == nil)
  }
}

// MARK: - Authorization Fixture

private extension ReflectionPersistenceTests {
  func reflectionAuthorization(
    _ env: BoundRunEnvironment,
    fixture: BoundRunEnvironment.ReflectionFixture,
    claim: ClaimedOperation
  ) -> LearningAuthorization {
    LearningAuthorization(
      operationId: claim.id,
      carrier: CarrierAuthorization(
        sourceDigest: fixture.trigger.digest.rawValue,
        digest: CarrierDigest(rawValue: "frozen-carrier"),
        isPermitted: true
      ),
      estimatedTokens: 1_000,
      estimatedCostUSD: 0.01,
      configuredRoute: "openai-compatible/test-model",
      providerCallID: UUIDProviderCallIDGenerator().next(),
      budget: env.gate(proactiveCapUSD: BoundRunEnvironment.unboundedProactiveCapUSD),
      context: .reflection(ReflectionAuthorization(preparation: fixture.preparation))
    )
  }
}
