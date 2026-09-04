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

  @Test func candidateCompletionCommitsArtifactSpendAndTerminalStateWithoutAdmission() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: started)
    let initialState = try env.currentLearningState()

    // when
    let committed = try env.learning.finishOperation(
      env.reflectionResult(operation: started, product: .candidate(artifact)),
      now: env.now
    )

    // then — splitting any one write out of finish would expose a succeeded partial artifact
    #expect(committed)
    #expect(try env.operationState(started.id) == .succeeded)
    #expect(try env.learningUsage(operationId: started.id).count == 1)
    #expect(try env.learning.candidateArtifact(digest: artifact.digest) == artifact)
    #expect(try env.countRows(in: "learning_candidates") == 1)
    #expect(try env.countRows(in: "learning_trials") == 0)
    #expect(try env.currentLearningState() == initialState)
  }

  @Test(arguments: ManifestByteCorruption.allCases)
  func candidateArtifactRejectsChangedOrNonCanonicalManifestBytes(
    _ corruption: ManifestByteCorruption
  ) throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let operation = try env.startReflector(fixture)
    let baseline = try env.candidate(fixture: fixture, operation: operation)
    let schemaVersion =
      corruption == .wrongSchema
      ? CandidateSourceManifest.currentSchemaVersion + 1
      : CandidateSourceManifest.currentSchemaVersion
    let artifact = try artifactWithFeedback(baseline, schemaVersion: schemaVersion)
    try insertArtifactForReload(artifact, env: env)
    if corruption != .wrongSchema {
      let bytes = try corruptedManifestBytes(for: artifact, corruption: corruption)
      try replaceManifestBytes(bytes, digest: artifact.digest, env: env)
    }

    // when, then — Codable accepting unknown keys, a stale schema, or noncanonical bytes lets a
    // changed durable manifest collapse back onto the original trusted candidate identity
    #expect(throws: StoreError.self) {
      try env.learning.candidateArtifact(digest: artifact.digest)
    }
  }

  @Test(arguments: CandidateRowMismatch.allCases)
  func candidateArtifactRejectsManifestRowProjectionMismatch(
    _ mismatch: CandidateRowMismatch
  ) throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let operation = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: operation)
    try insertArtifactForReload(artifact, env: env)
    let lookup = try applyRowMismatch(mismatch, artifact: artifact, env: env)

    // when, then — omitting any denormalized projection comparison would let a corrupt row become
    // the admission handoff even though its immutable manifest describes another artifact
    #expect(throws: StoreError.self) {
      try env.learning.candidateArtifact(digest: lookup)
    }
  }

  @Test func noCandidateCompletionWritesOnlyACompactReceiptAndSpend() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let result = try env.noCandidate(fixture: fixture, operation: started)

    // when
    let committed = try env.learning.finishOperation(
      env.reflectionResult(operation: started, product: .noCandidate(result)),
      now: env.now
    )

    // then — persisting payload or lesson bytes would turn a negative receipt into another artifact
    #expect(committed)
    #expect(try env.operationState(started.id) == .succeeded)
    #expect(try env.learningUsage(operationId: started.id).count == 1)
    #expect(try env.countRows(in: "learning_candidates") == 0)
    let receipt = try #require(try reflectionDecision(env))
    #expect(receipt.kind == "reflection_no_candidate")
    #expect(receipt.inputs == ["carrier_digest", "operation_id", "trigger_digest"])
    #expect(receipt.result == ["result_digest"])
    #expect(receipt.algorithm == LearningAlgorithm.v1.rawValue)
  }

  @Test func wrongPhaseProductRollsBackClosureAndSpend() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)

    // when
    let failure: StoreError?
    do {
      _ = try env.learning.finishOperation(
        env.reflectionResult(operation: started, product: .evaluation(env.verdict())),
        now: env.now
      )
      failure = nil
    } catch let error {
      failure = error
    }

    // then — accepting an evaluator product would make the closed result union merely cosmetic
    guard case .unexpected = failure else {
      Issue.record("expected a mapped wrong-phase failure")
      return
    }
    #expect(try env.operationState(started.id) == .started)
    #expect(try env.learningUsage(operationId: started.id).isEmpty)
    #expect(try env.countRows(in: "learning_evaluations") == 2)
  }

  @Test func evaluatorCannotCommitAReflectionProduct() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let reflector = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: reflector)
    let evaluator = try env.startedOperation(try env.evaluatorKey())

    // when
    let failure: StoreError?
    do {
      _ = try env.learning.finishOperation(
        env.reflectionResult(operation: evaluator, product: .candidate(artifact)),
        now: env.now
      )
      failure = nil
    } catch let error {
      failure = error
    }

    // then — without the opposite phase arm, a false-current artifact still closes an evaluator
    guard case .unexpected = failure else {
      Issue.record("expected a mapped wrong-phase failure")
      return
    }
    #expect(try env.operationState(evaluator.id) == .started)
    #expect(try env.learningUsage(operationId: evaluator.id).isEmpty)
  }

  @Test(arguments: ReflectionProductIdentityMismatch.allCases)
  func reflectionFinishRejectsMismatchedProductIdentities(
    _ mismatch: ReflectionProductIdentityMismatch
  ) throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let operation = try env.startReflector(fixture)
    let product = try mismatchedProduct(
      mismatch,
      env: env,
      fixture: fixture,
      operation: operation
    )

    // when
    let committed = try env.learning.finishOperation(
      env.reflectionResult(operation: operation, product: product),
      now: env.now
    )

    // then — dropping one product-to-operation identity check would persist authority from a
    // different trigger, call, schema, origin, or predecessor while still charging this call
    #expect(committed)
    #expect(try env.operationState(operation.id) == .succeeded)
    #expect(try env.learningUsage(operationId: operation.id).count == 1)
    #expect(try env.countRows(in: "learning_candidates") == 0)
    #expect(try env.countRows(in: "learning_decisions") == 0)
  }

  @Test func artifactConstraintFailureRollsBackClosureAndSpend() throws {
    // given — the same immutable artifact already exists, forcing the terminal transaction to fail
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: started)
    try env.queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(db, artifact: artifact, now: env.now)
    }

    // when
    let failure: StoreError?
    do {
      _ = try env.learning.finishOperation(
        env.reflectionResult(operation: started, product: .candidate(artifact)),
        now: env.now
      )
      failure = nil
    } catch let error {
      failure = error
    }

    // then — committing operation or usage before the candidate INSERT would leave a torn result
    #expect(failure != nil)
    #expect(try env.operationState(started.id) == .started)
    #expect(try env.learningUsage(operationId: started.id).isEmpty)
    #expect(try env.countRows(in: "learning_candidates") == 1)
  }

  @Test func staleResultClosesAndChargesButPersistsNoArtifact() throws {
    // given — authorization succeeded before the source cutoff advanced
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: started)
    try env.advanceFeedbackRevision()

    // when
    let committed = try env.learning.finishOperation(
      env.reflectionResult(operation: started, product: .candidate(artifact)),
      now: env.now
    )

    // then — dropping the finish-time cutoff check would persist late output against newer state
    #expect(committed)
    #expect(try env.operationState(started.id) == .succeeded)
    #expect(try env.learningUsage(operationId: started.id).count == 1)
    #expect(try env.countRows(in: "learning_candidates") == 0)
    #expect(try env.learning.candidateArtifact(digest: artifact.digest) == nil)
  }

  @Test func staleNoCandidateClosesAndChargesWithoutWritingAReceipt() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let result = try env.noCandidate(fixture: fixture, operation: started)
    try env.advanceFeedbackRevision()

    // when
    let committed = try env.learning.finishOperation(
      env.reflectionResult(operation: started, product: .noCandidate(result)),
      now: env.now
    )

    // then — a stale null result is no more authoritative than a stale replacement
    #expect(committed)
    #expect(try env.operationState(started.id) == .succeeded)
    #expect(try env.learningUsage(operationId: started.id).count == 1)
    #expect(try env.countRows(in: "learning_decisions") == 0)
  }

  @Test func noCandidateConstraintFailureRollsBackClosureAndSpend() throws {
    // given — a database-level failure occurs at the final receipt insert
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let result = try env.noCandidate(fixture: fixture, operation: started)
    try env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_reflection_receipt BEFORE INSERT ON learning_decisions
          BEGIN SELECT RAISE(ABORT, 'forced receipt failure'); END
          """
      )
    }

    // when
    let failure: StoreError?
    do {
      _ = try env.learning.finishOperation(
        env.reflectionResult(operation: started, product: .noCandidate(result)),
        now: env.now
      )
      failure = nil
    } catch let error {
      failure = error
    }

    // then — committing closure or spend before the receipt would tear null-result completion
    #expect(failure != nil)
    #expect(try env.operationState(started.id) == .started)
    #expect(try env.learningUsage(operationId: started.id).isEmpty)
    #expect(try env.countRows(in: "learning_decisions") == 0)
  }

  @Test func interruptedReflectorKeepsTheProviderRecoverySuccessorGeneration() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let key = started.key

    // when
    _ = try env.learning.reconcileOperationsAtBoot(now: env.now)
    let successor = try #require(try env.learning.claimOperation(key, now: env.now))

    // then — removing M1 recovery would strand an ambiguous provider-level attempt forever
    #expect(try env.operationState(started.id) == .interruptedUnknown)
    #expect(successor.attemptGeneration == 2)
    #expect(successor.supersedes == started.id)
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

// MARK: - Artifact Corruption Fixtures

enum ManifestByteCorruption: CaseIterable, Sendable {
  case unknownTopLevel
  case unknownEvidence
  case unknownEvaluation
  case unknownFeedback
  case wrongSchema
  case nonCanonical
}

enum CandidateRowMismatch: CaseIterable, Sendable {
  case algorithm
  case epoch
  case baseDigest
  case baseRevision
  case feedbackRevision
  case origin
  case predecessor
  case replacementDigest
  case rowJob
  case manifestJob
  case candidateIdentity
}

enum ReflectionProductIdentityMismatch: CaseIterable, Sendable {
  case candidateOperation
  case candidateCarrier
  case candidateTrigger
  case candidateSchema
  case candidateOrigin
  case candidatePredecessor
  case candidatePredecessorFeedback
  case noCandidateOperation
  case noCandidateCarrier
  case noCandidateTrigger
}

private func artifactWithFeedback(
  _ artifact: CandidateArtifact,
  schemaVersion: Int
) throws -> CandidateArtifact {
  let manifest = artifact.manifest
  let feedback = CandidateFeedbackSource(
    eventId: 91,
    digest: FeedbackEventDigest(rawValue: "feedback-event"),
    revision: manifest.feedbackRevision,
    subjectKind: .run,
    subjectDigest: String(manifest.evidence[0].runId),
    signal: .resultCorrection
  )
  return try CandidateArtifact(
    replacement: artifact.replacement,
    manifest: copyManifest(
      manifest,
      schemaVersion: schemaVersion,
      feedback: [feedback]
    )
  )
}

private func insertArtifactForReload(
  _ artifact: CandidateArtifact,
  env: BoundRunEnvironment
) throws {
  try env.queue.write { db in
    try ScheduledLearningStoreGRDB.recordCandidateArtifact(db, artifact: artifact, now: env.now)
  }
}

private func corruptedManifestBytes(
  for artifact: CandidateArtifact,
  corruption: ManifestByteCorruption
) throws -> Data {
  let original = try CanonicalJSON.data(encoding: artifact.manifest)
  if corruption == .nonCanonical {
    return original + Data(" ".utf8)
  }
  var object = try manifestObject(original)
  switch corruption {
  case .unknownTopLevel:
    object["unexpected"] = true
  case .unknownEvidence:
    var values = try nestedObjects(object, key: "evidence")
    values[0]["unexpected"] = true
    object["evidence"] = values
  case .unknownEvaluation:
    var values = try nestedObjects(object, key: "evaluations")
    values[0]["unexpected"] = true
    object["evaluations"] = values
  case .unknownFeedback:
    var values = try nestedObjects(object, key: "feedback")
    values[0]["unexpected"] = true
    object["feedback"] = values
  case .wrongSchema, .nonCanonical:
    throw ArtifactFixtureError.unsupportedCorruption
  }
  return try CanonicalJSON.data(fromJSONObject: object)
}

private func manifestObject(_ bytes: Data) throws -> [String: Any] {
  guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
    throw ArtifactFixtureError.manifestIsNotAnObject
  }
  return object
}

private func nestedObjects(
  _ object: [String: Any],
  key: String
) throws -> [[String: Any]] {
  guard let values = object[key] as? [[String: Any]], values.isEmpty == false else {
    throw ArtifactFixtureError.missingNestedObject(key)
  }
  return values
}

private func replaceManifestBytes(
  _ bytes: Data,
  digest: CandidateDigest,
  env: BoundRunEnvironment
) throws {
  // swiftlint:disable:next optional_data_string_conversion
  let json = String(decoding: bytes, as: UTF8.self)
  try env.queue.write { db in
    try db.execute(
      sql: "UPDATE learning_candidates SET source_manifest = ? WHERE candidate_digest = ?",
      arguments: [json, digest.rawValue]
    )
  }
}

private func applyRowMismatch(
  _ mismatch: CandidateRowMismatch,
  artifact: CandidateArtifact,
  env: BoundRunEnvironment
) throws -> CandidateDigest {
  switch mismatch {
  case .algorithm:
    try updateCandidateColumn(
      "algorithm",
      value: "scheduled-learning/v2",
      artifact: artifact,
      env: env
    )
  case .epoch:
    try updateCandidateColumn(
      "learning_epoch",
      value: artifact.manifest.epoch.value + 1,
      artifact: artifact,
      env: env
    )
  case .baseDigest:
    try updateCandidateColumn("base_digest", value: "changed-base", artifact: artifact, env: env)
  case .baseRevision:
    try updateCandidateColumn(
      "base_revision",
      value: artifact.manifest.baseRevision.value + 1,
      artifact: artifact,
      env: env
    )
  case .feedbackRevision:
    try updateCandidateColumn(
      "frozen_feedback_revision",
      value: artifact.manifest.feedbackRevision.value + 1,
      artifact: artifact,
      env: env
    )
  case .origin:
    try updateCandidateColumn(
      "origin",
      value: CandidateOrigin.ownerEdit.rawValue,
      artifact: artifact,
      env: env
    )
  case .predecessor:
    try updateCandidateColumn(
      "predecessor_digest",
      value: "changed-predecessor",
      artifact: artifact,
      env: env
    )
  case .replacementDigest:
    let replacement = try LessonSet.canonical(jobId: env.jobId, lessons: ["A different lesson."])
    try insertLessonSet(replacement, env: env)
    try updateCandidateColumn(
      "replacement_digest",
      value: replacement.digest.rawValue,
      artifact: artifact,
      env: env
    )
  case .rowJob:
    let otherJobId = env.jobId + 10_000
    let replacement = try LessonSet.canonical(
      jobId: otherJobId,
      lessons: artifact.replacement.lessons
    )
    try insertLessonSet(replacement, env: env)
    try updateCandidateColumn("job_id", value: otherJobId, artifact: artifact, env: env)
  case .manifestJob:
    let changedManifest = copyManifest(
      artifact.manifest,
      jobId: env.jobId + 20_000,
      feedback: artifact.manifest.feedback
    )
    let changedArtifact = try CandidateArtifact(
      replacement: artifact.replacement,
      manifest: changedManifest
    )
    let bytes = try CanonicalJSON.data(encoding: changedManifest)
    // swiftlint:disable:next optional_data_string_conversion
    let json = String(decoding: bytes, as: UTF8.self)
    try env.queue.write { db in
      try db.execute(
        sql: """
          UPDATE learning_candidates SET candidate_digest = ?, source_manifest = ?
          WHERE candidate_digest = ?
          """,
        arguments: [changedArtifact.digest.rawValue, json, artifact.digest.rawValue]
      )
    }
    return changedArtifact.digest
  case .candidateIdentity:
    let changed = CandidateDigest(rawValue: "changed-candidate-identity")
    try updateCandidateColumn(
      "candidate_digest",
      value: changed.rawValue,
      artifact: artifact,
      env: env
    )
    return changed
  }
  return artifact.digest
}

private func updateCandidateColumn(
  _ column: String,
  value: some DatabaseValueConvertible,
  artifact: CandidateArtifact,
  env: BoundRunEnvironment
) throws {
  try env.queue.write { db in
    try db.execute(
      sql: "UPDATE learning_candidates SET \(column) = ? WHERE candidate_digest = ?",
      arguments: [value, artifact.digest.rawValue]
    )
  }
}

private func insertLessonSet(_ lessonSet: LessonSet, env: BoundRunEnvironment) throws {
  try env.queue.write { db in
    try db.execute(
      sql: """
        INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        lessonSet.jobId,
        lessonSet.digest.rawValue,
        lessonSet.schemaVersion,
        lessonSet.canonicalBytes,
        LessonSetSource.reflectorCandidate.rawValue,
        EpochSecondCodec.epoch(env.now),
      ]
    )
  }
}

private func mismatchedProduct(
  _ mismatch: ReflectionProductIdentityMismatch,
  env: BoundRunEnvironment,
  fixture: BoundRunEnvironment.ReflectionFixture,
  operation: ClaimedOperation
) throws -> LearningOperationProduct {
  switch mismatch {
  case .candidateOperation, .candidateCarrier, .candidateTrigger, .candidateSchema,
    .candidateOrigin, .candidatePredecessor, .candidatePredecessorFeedback:
    let artifact = try env.candidate(fixture: fixture, operation: operation)
    let manifest = copyManifest(artifact.manifest, productMismatch: mismatch)
    return .candidate(try CandidateArtifact(replacement: artifact.replacement, manifest: manifest))
  case .noCandidateOperation, .noCandidateCarrier, .noCandidateTrigger:
    let result = try env.noCandidate(fixture: fixture, operation: operation)
    return .noCandidate(copyNoCandidate(result, mismatch: mismatch))
  }
}

private func copyManifest(
  _ manifest: CandidateSourceManifest,
  schemaVersion: Int? = nil,
  jobId: Int64? = nil,
  feedback: [CandidateFeedbackSource]
) -> CandidateSourceManifest {
  CandidateSourceManifest(
    schemaVersion: schemaVersion ?? manifest.schemaVersion,
    origin: manifest.origin,
    algorithm: manifest.algorithm,
    jobId: jobId ?? manifest.jobId,
    epoch: manifest.epoch,
    triggerDigest: manifest.triggerDigest,
    triggerReason: manifest.triggerReason,
    qualifyingIssueCodes: manifest.qualifyingIssueCodes,
    operationId: manifest.operationId,
    carrierDigest: manifest.carrierDigest,
    resultDigest: manifest.resultDigest,
    baseDigest: manifest.baseDigest,
    baseRevision: manifest.baseRevision,
    feedbackRevision: manifest.feedbackRevision,
    evidence: manifest.evidence,
    evaluations: manifest.evaluations,
    feedback: feedback,
    predecessorCandidate: manifest.predecessorCandidate,
    predecessorFeedback: manifest.predecessorFeedback
  )
}

private func copyManifest(
  _ manifest: CandidateSourceManifest,
  productMismatch: ReflectionProductIdentityMismatch
) -> CandidateSourceManifest {
  let predecessorFeedback = CandidateFeedbackSource(
    eventId: 92,
    digest: FeedbackEventDigest(rawValue: "predecessor-feedback"),
    revision: manifest.feedbackRevision,
    subjectKind: .candidate,
    subjectDigest: "predecessor-candidate",
    signal: .candidateApprove
  )
  return CandidateSourceManifest(
    schemaVersion: productMismatch == .candidateSchema
      ? manifest.schemaVersion + 1 : manifest.schemaVersion,
    origin: productMismatch == .candidateOrigin ? .ownerEdit : manifest.origin,
    algorithm: manifest.algorithm,
    jobId: manifest.jobId,
    epoch: manifest.epoch,
    triggerDigest:
      productMismatch == .candidateTrigger
      ? TriggerDigest(rawValue: "different-trigger")
      : manifest.triggerDigest,
    triggerReason: manifest.triggerReason,
    qualifyingIssueCodes: manifest.qualifyingIssueCodes,
    operationId:
      productMismatch == .candidateOperation
      ? LearningOperationID(rawValue: "different-operation")
      : manifest.operationId,
    carrierDigest:
      productMismatch == .candidateCarrier
      ? CarrierDigest(rawValue: "different-carrier")
      : manifest.carrierDigest,
    resultDigest: manifest.resultDigest,
    baseDigest: manifest.baseDigest,
    baseRevision: manifest.baseRevision,
    feedbackRevision: manifest.feedbackRevision,
    evidence: manifest.evidence,
    evaluations: manifest.evaluations,
    feedback: manifest.feedback,
    predecessorCandidate:
      productMismatch == .candidatePredecessor
      ? CandidateDigest(rawValue: "predecessor-candidate")
      : manifest.predecessorCandidate,
    predecessorFeedback:
      productMismatch == .candidatePredecessorFeedback
      ? predecessorFeedback
      : manifest.predecessorFeedback
  )
}

private func copyNoCandidate(
  _ result: NoCandidateResult,
  mismatch: ReflectionProductIdentityMismatch
) -> NoCandidateResult {
  NoCandidateResult(
    algorithm: result.algorithm,
    triggerDigest:
      mismatch == .noCandidateTrigger
      ? TriggerDigest(rawValue: "different-trigger")
      : result.triggerDigest,
    operationId:
      mismatch == .noCandidateOperation
      ? LearningOperationID(rawValue: "different-operation")
      : result.operationId,
    carrierDigest:
      mismatch == .noCandidateCarrier
      ? CarrierDigest(rawValue: "different-carrier")
      : result.carrierDigest,
    resultDigest: result.resultDigest,
    authorization: result.authorization
  )
}

private enum ArtifactFixtureError: Error {
  case manifestIsNotAnObject
  case missingNestedObject(String)
  case unsupportedCorruption
}

// MARK: - Test Reads

private extension ReflectionPersistenceTests {
  struct DecisionRow {
    let kind: String
    let inputs: Set<String>
    let result: Set<String>
    let algorithm: String
  }

  func reflectionDecision(_ env: BoundRunEnvironment) throws -> DecisionRow? {
    try env.queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT kind, inputs, result, algorithm FROM learning_decisions"
        )
      else {
        return nil
      }
      let inputsJSON = try JSONSerialization.jsonObject(with: Data((row["inputs"] as String).utf8))
      let resultJSON = try JSONSerialization.jsonObject(with: Data((row["result"] as String).utf8))
      guard
        let inputs = inputsJSON as? [String: Any],
        let result = resultJSON as? [String: Any]
      else {
        throw StoreError.unexpected("reflection decision is not a pair of objects")
      }
      return DecisionRow(
        kind: row["kind"],
        inputs: Set(inputs.keys),
        result: Set(result.keys),
        algorithm: row["algorithm"]
      )
    }
  }

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
