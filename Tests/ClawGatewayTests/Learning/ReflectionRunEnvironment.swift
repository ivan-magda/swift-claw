import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Logging

@testable import ClawData
@testable import ClawGateway

struct ReflectionRunEnvironment {
  static let route = "openai-compatible/reflection-model"
  static let issueCode = "material.missed"
  static let candidateReply =
    #"{"schema_version":1,"candidate":{"lessons":["Report only material changes."]}}"#

  let queue: DatabaseQueue
  let jobs: ScheduledJobStoreGRDB
  let learning: ScheduledLearningStoreGRDB
  let authorizing: RecordingLearningStore
  let provider: SequenceProvider
  let runner: LearningOperationRunner
  let jobId: Int64
  let trigger: TriggerIdentity
  let now: Date

  static func make(
    reply: String = candidateReply,
    repeatable: Bool = true,
    finalOutput: String = "The result missed a material change.",
    secretValues: [String] = [],
    proactivePerDayUSD: Double = RunBudget.default.proactivePerDayUSD
  ) throws -> ReflectionRunEnvironment {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let now = Date(timeIntervalSince1970: 1_782_000_600)
    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let recurrence =
      repeatable
      ? SchedulingRuleFixtures.weekdayEnvelope(zone: TimeZone(secondsFromGMT: 0) ?? .gmt)
      : nil
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatId: 777,
        label: "digest",
        prompt: "Check the page for material changes.",
        recurrence: recurrence,
        timezone: "UTC",
        nextOccurrence: now
      ),
      now: now
    )
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    _ = try learning.armJob(jobId: job.id, now: now)
    let runs = RunStoreGRDB(writer: queue)
    let first = try evaluatedEvidence(
      jobs: jobs,
      runs: runs,
      learning: learning,
      jobId: job.id,
      output: finalOutput,
      now: now
    )
    let second = try evaluatedEvidence(
      jobs: jobs,
      runs: runs,
      learning: learning,
      jobId: job.id,
      output: finalOutput,
      now: now
    )
    guard let stableDigest = first.payload?.effectiveLessonSetDigest else {
      throw StoreError.unexpected("reflection fixture evidence has no stable lesson digest")
    }
    let trigger = TriggerIdentity(
      jobId: job.id,
      epoch: first.epoch,
      algorithm: .v1,
      stableDigest: LessonSetDigest(rawValue: stableDigest),
      evidenceDigests: [first.digest, second.digest],
      feedbackRevision: FeedbackRevision(0),
      issueCodes: [issueCode],
      reason: .recurringIssue
    )
    let response = ChatResponse(
      content: reply,
      finishReason: "stop",
      usage: ChatUsage(promptTokens: 350, completionTokens: 50, totalTokens: 400),
      costFromProvider: 0.004
    )
    let provider = SequenceProvider([response])
    let binding = LLMRouteBinding(
      provider: provider,
      wireModel: route,
      configuredReference: route,
      costPolicy: .metered,
      reservationPolicy: .textOnly
    )
    let authorizing = RecordingLearningStore(base: learning)
    return ReflectionRunEnvironment(
      queue: queue,
      jobs: jobs,
      learning: learning,
      authorizing: authorizing,
      provider: provider,
      runner: LearningOperationRunner(
        learning: authorizing,
        jobs: jobs,
        roster: ProviderRoster(primary: binding),
        budget: budget(proactivePerDayUSD: proactivePerDayUSD),
        costResolver: CostResolver(
          priceTable: .empty,
          referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
        ),
        redactor: SecretRedactor(secretValues: secretValues),
        logger: TestLog.silent
      ),
      jobId: job.id,
      trigger: trigger,
      now: now
    )
  }
}

// MARK: - Reads and Mutations

extension ReflectionRunEnvironment {
  func operationState() throws -> LearningOperationState? {
    try stringColumn("state").flatMap(LearningOperationState.init(rawValue:))
  }

  func failureCode() throws -> LearningOperationFailure? {
    try stringColumn("failure_code").flatMap(LearningOperationFailure.init(rawValue:))
  }

  func candidate() throws -> CandidateArtifact? {
    let raw = try queue.read { db in
      try String.fetchOne(db, sql: "SELECT candidate_digest FROM learning_candidates")
    }
    guard let raw else {
      return nil
    }
    return try learning.candidateArtifact(digest: CandidateDigest(rawValue: raw))
  }

  func rowCount(_ table: String) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
    }
  }

  func cancelJob() throws {
    guard try jobs.cancel(id: jobId, now: now) != nil else {
      throw StoreError.unexpected("reflection fixture job refused cancellation")
    }
  }

  func openLiveTrialWithoutPointer() throws {
    let replacement = try LessonSet.canonical(jobId: jobId, lessons: ["trial lesson"])
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          jobId,
          replacement.digest.rawValue,
          replacement.schemaVersion,
          replacement.canonicalBytes,
          LessonSetSource.reflectorCandidate.rawValue,
          EpochSecondCodec.epoch(now),
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO learning_candidates(candidate_digest, job_id, learning_epoch,
            replacement_digest, base_digest, base_revision, frozen_feedback_revision, origin,
            source_manifest, algorithm, created_at)
          VALUES ('live-candidate', ?, ?, ?, ?, 0, 0, ?, '{}', ?, ?)
          """,
        arguments: [
          jobId,
          trigger.epoch.value,
          replacement.digest.rawValue,
          trigger.stableDigest.rawValue,
          CandidateOrigin.reflection.rawValue,
          LearningAlgorithm.v1.rawValue,
          EpochSecondCodec.epoch(now),
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, 'live-candidate', 1, ?, ?, ?, 5, 0, ?, ?, ?)
          """,
        arguments: [
          jobId,
          trigger.epoch.value,
          trigger.stableDigest.rawValue,
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

  func hardVetoedTrigger() throws -> TriggerIdentity {
    let sources = try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT evaluation_digest, run_id FROM learning_evaluations
          WHERE job_id = ? ORDER BY created_at, run_id LIMIT 2
          """,
        arguments: [jobId]
      )
    }
    guard sources.count == 2 else {
      throw StoreError.unexpected("reflection fixture lacks two evaluation dependencies")
    }
    let disputed = sources[0]
    let corrected = sources[1]
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO feedback_events(job_id, learning_epoch, subject_kind, subject_digest, signal,
            actor, feedback_revision, occurred_at)
          VALUES (?, ?, ?, ?, ?, ?, 1, ?)
          """,
        arguments: [
          jobId,
          trigger.epoch.value,
          FeedbackSubjectKind.evaluation.rawValue,
          disputed["evaluation_digest"] as String,
          OwnerSignal.evaluationDispute.rawValue,
          AuditActor.owner.rawValue,
          EpochSecondCodec.epoch(now),
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO feedback_events(job_id, learning_epoch, subject_kind, subject_digest, signal,
            payload, actor, feedback_revision, occurred_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, 2, ?)
          """,
        arguments: [
          jobId,
          trigger.epoch.value,
          FeedbackSubjectKind.run.rawValue,
          String(corrected["run_id"] as Int64),
          OwnerSignal.resultCorrection.rawValue,
          "The result still missed the material change.",
          AuditActor.owner.rawValue,
          EpochSecondCodec.epoch(now),
        ]
      )
      try db.execute(
        sql: "UPDATE job_learning_state SET feedback_revision = 2 WHERE job_id = ?",
        arguments: [jobId]
      )
    }
    return TriggerIdentity(
      jobId: trigger.jobId,
      epoch: trigger.epoch,
      algorithm: trigger.algorithm,
      stableDigest: trigger.stableDigest,
      evidenceDigests: trigger.evidenceDigests,
      feedbackRevision: FeedbackRevision(2),
      issueCodes: [],
      reason: .ownerCorrection
    )
  }
}

// MARK: - Fixture Setup

private extension ReflectionRunEnvironment {
  static func evaluatedEvidence(
    jobs: ScheduledJobStoreGRDB,
    runs: RunStoreGRDB,
    learning: ScheduledLearningStoreGRDB,
    jobId: Int64,
    output: String,
    now: Date
  ) throws -> SealedEvidence {
    guard case .fired(let fire) = try jobs.fireNow(jobId: jobId, now: now) else {
      throw StoreError.unexpected("reflection fixture job refused to fire")
    }
    _ = try runs.pickUp(runId: fire.runId, now: now)
    try learning.freezeCompatibility(
      runId: fire.runId,
      surface: RunSurface(
        toolCatalogDigest: "tools-v1",
        policyVersion: "pv16",
        skillSetDigest: "skills-v1",
        configuredRoute: route
      )
    )
    _ = try runs.commitAssistantTurn(
      assistantTurn(runId: fire.runId, sessionId: fire.sessionId, output: output),
      now: now
    )
    _ = try learning.sealEvidence(runId: fire.runId, now: now)
    guard let evidence = try learning.evidence(runId: fire.runId) else {
      throw StoreError.unexpected("reflection fixture failed to seal evidence")
    }
    let key = LearningOperationKey(
      jobId: jobId,
      epoch: evidence.epoch,
      phase: .evaluator,
      sourceDigest: evidence.digest.rawValue,
      promptVersion: EvaluatorPrompt.v1.version,
      schemaVersion: EvaluatorOutput.currentSchemaVersion,
      rubricVersion: EvaluatorRubric.v1.version
    )
    guard let claim = try learning.claimOperation(key, now: now) else {
      throw StoreError.unexpected("reflection fixture failed to claim evaluator")
    }
    let authorization = LearningAuthorization(
      operationId: claim.id,
      carrier: CarrierAuthorization(
        sourceDigest: evidence.digest.rawValue,
        digest: CarrierDigest(rawValue: "fixture-\(fire.runId)"),
        isPermitted: true
      ),
      estimatedTokens: 100,
      estimatedCostUSD: 0.001,
      configuredRoute: route,
      providerCallID: UUIDProviderCallIDGenerator().next(),
      budget: BudgetGate(budget: budget(proactivePerDayUSD: 1_000))
    )
    guard try learning.authorizeAndStartOperation(authorization, now: now) == .started else {
      throw StoreError.unexpected("reflection fixture failed to start evaluator")
    }
    let result = LearningOperationResult(
      operationId: claim.id,
      usage: LearningCallUsage(
        model: route,
        promptTokens: 100,
        completionTokens: 20,
        costUSD: 0.001,
        costSource: .providerReturned,
        isEstimated: false
      ),
      product: .evaluation(
        LearningEvaluation(
          outcome: .reusableIssue,
          issueCodes: [issueCode],
          evaluator: EvaluatorSurface(
            route: route,
            promptVersion: EvaluatorPrompt.v1.version,
            schemaVersion: EvaluatorOutput.currentSchemaVersion,
            rubricVersion: EvaluatorRubric.v1.version
          )
        )
      )
    )
    guard try learning.finishOperation(result, now: now) else {
      throw StoreError.unexpected("reflection fixture failed to finish evaluator")
    }
    return evidence
  }

  static func assistantTurn(
    runId: Int64,
    sessionId: Int64,
    output: String
  ) -> AssistantTurn {
    AssistantTurn(
      runId: runId,
      sessionId: sessionId,
      chatId: 777,
      content: output,
      usage: usageFixture(sessionId: sessionId, runId: runId, model: route),
      chunks: [
        OutboxChunk(
          stepIndex: 0,
          chatId: 777,
          payload: output,
          payloadHash: ContentHash.fnv1a(output)
        )
      ]
    )
  }

  static func budget(proactivePerDayUSD: Double) -> RunBudget {
    let base = RunBudget.default
    return RunBudget(
      maxInputTokens: base.maxInputTokens,
      maxOutputTokens: base.maxOutputTokens,
      wallClockDeadlineSeconds: base.wallClockDeadlineSeconds,
      retryBudget: base.retryBudget,
      perRunUSD: base.perRunUSD,
      perDayUSD: base.perDayUSD,
      proactivePerDayUSD: proactivePerDayUSD,
      referenceUSDPerToken: base.referenceUSDPerToken
    )
  }

  func operationId() -> LearningOperationID {
    let key = LearningOperationKey(
      jobId: jobId,
      epoch: trigger.epoch,
      phase: .reflector,
      sourceDigest: trigger.digest.rawValue,
      promptVersion: ReflectorPrompt.v1.version,
      schemaVersion: ReflectorOutput.currentSchemaVersion,
      rubricVersion: ReflectorRubric.v1
    )
    return LearningOperationID(key: key.digest, attemptGeneration: 1)
  }

  func stringColumn(_ column: String) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT \(column) FROM learning_operations WHERE operation_id = ?",
        arguments: [operationId().rawValue]
      )
    }
  }
}
