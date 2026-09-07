import ClawCore
import ClawTestSupport
import Foundation
import GRDB

@testable import ClawData

extension BoundRunEnvironment {
  struct ReflectionFixture {
    let trigger: TriggerIdentity
    let preparation: ReflectionPreparation
  }

  func makeRepeatable() throws {
    let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    let recurrence = SchedulingRuleFixtures.weekdayEnvelope(zone: zone)
    try queue.write { db in
      try db.execute(
        sql: "UPDATE scheduled_jobs SET recurrence = ? WHERE id = ?",
        arguments: [try recurrence.encodedJSON(), jobId]
      )
    }
  }

  func reflectionFixture(
    issueCode: String = "material.missed"
  ) throws -> ReflectionFixture {
    try makeRepeatable()
    let first = try evaluatedEvidence(issueCode: issueCode)
    let second = try evaluatedEvidence(issueCode: issueCode)
    let trigger = TriggerIdentity(
      jobId: jobId,
      epoch: first.evidence.epoch,
      algorithm: .v1,
      stableDigest: try currentLearningState().stableDigest,
      evidenceDigests: [first.evidence.digest, second.evidence.digest],
      feedbackRevision: FeedbackRevision(0),
      issueCodes: [issueCode],
      reason: .recurringIssue
    )
    guard let preparation = try learning.prepareReflection(trigger: trigger) else {
      throw StoreError.unexpected("fixture trigger did not prepare")
    }
    return ReflectionFixture(trigger: trigger, preparation: preparation)
  }

  func evaluatedEvidence(
    issueCode: String,
    output: String = "The result missed a material change."
  ) throws -> (evidence: SealedEvidence, evaluation: CandidateEvaluationSource) {
    let runId = try runningBoundRun()
    try freezeSurface(runId: runId, skillSetDigest: Self.pickupSkillSetDigest)
    _ = try runs.commitAssistantTurn(
      assistantTurn(runId: runId, content: output),
      now: now
    )
    _ = try learning.sealEvidence(runId: runId, now: now)
    let evidence = try requireEvidence(runId: runId)
    let started = try startedOperation(evaluatorKey(for: evidence))
    _ = try learning.finishOperation(
      result(
        for: started.id,
        evaluation: verdict(outcome: .reusableIssue, issueCodes: [issueCode])
      ),
      now: now
    )
    let evaluationDigest = try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT evaluation_digest FROM learning_evaluations WHERE run_id = ?",
        arguments: [runId]
      )
    }
    guard let evaluationDigest else {
      throw StoreError.unexpected("fixture run \(runId) has no evaluation digest")
    }
    return (
      evidence,
      CandidateEvaluationSource(
        runId: runId,
        digest: EvaluationDigest(rawValue: evaluationDigest)
      )
    )
  }

  func startReflector(_ fixture: ReflectionFixture) throws -> ClaimedOperation {
    let key = LearningOperationKey(
      jobId: jobId,
      epoch: fixture.trigger.epoch,
      phase: .reflector,
      sourceDigest: fixture.trigger.digest.rawValue,
      promptVersion: ReflectorPrompt.v1.version,
      schemaVersion: ReflectorOutput.currentSchemaVersion,
      rubricVersion: ReflectorRubric.v1
    )
    let claim = try self.claim(key)
    let carrier = try ReflectorCarrier(
      stableLessons: fixture.preparation.stableLessons.lessons,
      evaluations: fixture.preparation.evaluations.map(\.summary),
      issueCodes: fixture.trigger.issueCodes,
      ownerPayloads: fixture.preparation.ownerPayloads.map(\.payload)
    )
    let bytes = try CanonicalJSON.data(encoding: carrier)
    let authorization = LearningAuthorization(
      operationId: claim.id,
      carrier: CarrierAuthorization(
        sourceDigest: fixture.trigger.digest.rawValue,
        digest: CarrierDigest(rawValue: SHA256Digest.hex(bytes)),
        isPermitted: true
      ),
      estimatedTokens: 1_000,
      estimatedCostUSD: 0.01,
      configuredRoute: "openai-compatible/test-model",
      providerCallID: UUIDProviderCallIDGenerator().next(),
      budget: gate(proactiveCapUSD: Self.unboundedProactiveCapUSD),
      context: .reflection(ReflectionAuthorization(preparation: fixture.preparation))
    )
    guard try learning.authorizeAndStartOperation(authorization, now: now) == .started else {
      throw StoreError.unexpected("reflector fixture did not start")
    }
    return claim
  }

  func reflectionResult(
    operation: ClaimedOperation,
    product: LearningOperationProduct
  ) -> LearningOperationResult {
    LearningOperationResult(
      operationId: operation.id,
      usage: LearningCallUsage(
        model: "openai-compatible/test-model",
        promptTokens: 900,
        completionTokens: 100,
        costUSD: 0.25,
        costSource: .providerReturned,
        isEstimated: false
      ),
      product: product
    )
  }

  func candidate(
    fixture: ReflectionFixture,
    operation: ClaimedOperation,
    lessons: [String] = ["Report only material changes."]
  ) throws -> CandidateArtifact {
    let replacement = try LessonSet.canonical(jobId: jobId, lessons: lessons)
    let carrierDigest = try requireCarrierDigest(operation.id)
    let resultDigest = ReflectionResultDigest.of(Data("candidate-result".utf8))
    let trigger = fixture.trigger
    return try CandidateArtifact(
      replacement: replacement,
      manifest: CandidateSourceManifest(
        origin: .reflection,
        algorithm: trigger.algorithm,
        jobId: jobId,
        epoch: trigger.epoch,
        triggerDigest: trigger.digest,
        triggerReason: trigger.reason,
        qualifyingIssueCodes: trigger.issueCodes,
        operationId: operation.id,
        carrierDigest: carrierDigest,
        resultDigest: resultDigest,
        baseDigest: trigger.stableDigest,
        baseRevision: fixture.preparation.stableRevision,
        feedbackRevision: trigger.feedbackRevision,
        evidence: fixture.preparation.evidenceSources,
        evaluations: fixture.preparation.evaluationSources,
        feedback: fixture.preparation.feedbackSources,
        predecessorCandidate: nil,
        predecessorFeedback: nil
      )
    )
  }

  func noCandidate(
    fixture: ReflectionFixture,
    operation: ClaimedOperation
  ) throws -> NoCandidateResult {
    NoCandidateResult(
      algorithm: .v1,
      triggerDigest: fixture.trigger.digest,
      operationId: operation.id,
      carrierDigest: try requireCarrierDigest(operation.id),
      resultDigest: ReflectionResultDigest.of(Data("no-candidate".utf8)),
      authorization: ReflectionAuthorization(preparation: fixture.preparation)
    )
  }

  func currentLearningState() throws -> JobLearningState {
    let row = try queue.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT * FROM job_learning_state WHERE job_id = ?",
        arguments: [jobId]
      )
    }
    guard let row else {
      throw StoreError.unexpected("fixture job has no learning state")
    }
    return JobLearningState(
      jobId: jobId,
      epoch: LearningEpoch(row["learning_epoch"]),
      stableDigest: LessonSetDigest(rawValue: row["stable_lesson_set_digest"]),
      stableRevision: StableRevision(row["stable_revision"]),
      openTrialId: row["open_trial_id"],
      feedbackRevision: FeedbackRevision(row["feedback_revision"])
    )
  }

  func countRows(in table: String) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
    }
  }

  func advanceFeedbackRevision() throws {
    try queue.write { db in
      try db.execute(
        sql:
          "UPDATE job_learning_state SET feedback_revision = feedback_revision + 1 WHERE job_id = ?",
        arguments: [jobId]
      )
    }
  }

  func insertLiveTrialWithoutPointer(candidate: CandidateArtifact) throws {
    try queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(db, artifact: candidate, now: now)
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, ?, 1, ?, ?, ?, 5, 0, ?, ?, ?)
          """,
        arguments: [
          jobId,
          candidate.manifest.epoch.value,
          candidate.manifest.baseDigest.rawValue,
          candidate.digest.rawValue,
          EpochSecondCodec.epoch(now),
          EpochSecondCodec.epoch(now.addingTimeInterval(3_600)),
          EpochSecondCodec.epoch(now.addingTimeInterval(7_200)),
          EpochSecondCodec.epoch(now),
          LearningTrialState.open.rawValue,
          LearningAlgorithm.v1.rawValue,
        ]
      )
    }
  }

  @discardableResult
  func appendFeedback(
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String,
    signal: OwnerSignal,
    payload: String? = nil,
    supersedes: Int64? = nil
  ) throws -> CandidateFeedbackSource {
    try queue.write { db in
      let revision =
        try Int64.fetchOne(
          db,
          sql: """
            UPDATE job_learning_state SET feedback_revision = feedback_revision + 1
            WHERE job_id = ? RETURNING feedback_revision
            """,
          arguments: [jobId]
        ) ?? -1
      try db.execute(
        sql: """
          INSERT INTO feedback_events(job_id, learning_epoch, subject_kind, subject_digest, signal,
            payload, actor, feedback_revision, supersedes, occurred_at)
          VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          jobId,
          subjectKind.rawValue,
          subjectDigest,
          signal.rawValue,
          payload,
          AuditActor.owner.rawValue,
          revision,
          supersedes,
          EpochSecondCodec.epoch(now),
        ]
      )
      return CandidateFeedbackSource(
        eventId: db.lastInsertedRowID,
        digest: try FeedbackEventDigest.of(
          eventId: db.lastInsertedRowID,
          jobId: jobId,
          epoch: LearningEpoch(1),
          subjectKind: subjectKind,
          subjectDigest: subjectDigest,
          signal: signal,
          payload: payload,
          actor: .owner,
          transportUpdateId: nil,
          revision: FeedbackRevision(revision),
          supersedes: supersedes,
          occurredAtEpochSecond: EpochSecondCodec.epoch(now)
        ),
        revision: FeedbackRevision(revision),
        subjectKind: subjectKind,
        subjectDigest: subjectDigest,
        signal: signal
      )
    }
  }

  func markAsClosedTrialEvidence(
    runId: Int64,
    candidate: CandidateArtifact
  ) throws {
    try queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(db, artifact: candidate, now: now)
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, ?, 1, ?, ?, ?, 5, 1, ?, ?, ?)
          """,
        arguments: [
          jobId,
          candidate.manifest.epoch.value,
          candidate.manifest.baseDigest.rawValue,
          candidate.digest.rawValue,
          EpochSecondCodec.epoch(now),
          EpochSecondCodec.epoch(now.addingTimeInterval(3_600)),
          EpochSecondCodec.epoch(now.addingTimeInterval(7_200)),
          EpochSecondCodec.epoch(now),
          LearningTrialState.closed.rawValue,
          LearningAlgorithm.v1.rawValue,
        ]
      )
      let trialId = db.lastInsertedRowID
      try db.execute(
        sql: "UPDATE run_learning_bindings SET trial_id = ?, trial_generation = 1 WHERE run_id = ?",
        arguments: [trialId, runId]
      )
    }
  }
}

// MARK: - Private Reads

private extension BoundRunEnvironment {
  func requireEvidence(runId: Int64) throws -> SealedEvidence {
    guard let evidence = try learning.evidence(runId: runId) else {
      throw StoreError.unexpected("fixture run \(runId) has no sealed evidence")
    }
    return evidence
  }

  func requireCarrierDigest(_ id: LearningOperationID) throws -> CarrierDigest {
    let raw = try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT carrier_digest FROM learning_operations WHERE operation_id = ?",
        arguments: [id.rawValue]
      )
    }
    guard let raw else {
      throw StoreError.unexpected("fixture operation has no carrier digest")
    }
    return CarrierDigest(rawValue: raw)
  }
}
