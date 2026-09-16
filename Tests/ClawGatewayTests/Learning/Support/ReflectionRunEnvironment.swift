import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Logging

@testable import ClawData
@testable import ClawGateway

struct ReflectionRunEnvironment {
  static let route = "openai-compatible/reflection-model"
  static let fallbackRoute = "openai-compatible/reflection-fallback"
  static let issueCode = "material.missed"

  static let candidateReply =
    #"{"schema_version":1,"candidate":{"lessons":["Report only material changes."]}}"#

  let queue: DatabaseQueue
  let jobs: ScheduledJobStoreGRDB
  let learning: ScheduledLearningStoreGRDB
  let runnerLearning: RecordingLearningStore
  let provider: SequenceProvider
  let fallbackProvider: SequenceProvider
  let callIDs: RecordingProviderCallIDGenerator
  let runner: LearningOperationRunner
  let jobID: Int64
  let trigger: TriggerIdentity
  let now: Date

  static func make(
    reply: String = candidateReply,
    repeatable: Bool = true,
    finalOutput: String = "The result missed a material change.",
    secretValues: [String] = [],
    proactivePerDayUSD: Double = RunBudget.default.proactivePerDayUSD,
    primaryFailure: (any Error & Sendable)? = nil,
    admissionFails: Bool = false,
    logger: Logger = TestLog.silent
  ) throws -> ReflectionRunEnvironment {
    let queue = try TestDatabase.make()
    let now = Date(timeIntervalSince1970: 1_782_000_600)
    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let recurrence =
      repeatable
      ? SchedulingRuleFixtures.weekdayEnvelope(zone: TimeZone(secondsFromGMT: 0) ?? .gmt) : nil
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatID: 777,
        label: "digest",
        prompt: "Check the page for material changes.",
        recurrence: recurrence,
        timezone: "UTC",
        nextOccurrence: now
      ),
      now: now
    )
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    _ = try TestLearningFixtures(writer: queue).seedArmedJob(jobID: job.id, now: now)
    let runs = RunStoreGRDB(writer: queue)
    let first = try evaluatedEvidence(
      jobs: jobs,
      runs: runs,
      learning: learning,
      jobID: job.id,
      output: finalOutput,
      now: now
    )
    let second = try evaluatedEvidence(
      jobs: jobs,
      runs: runs,
      learning: learning,
      jobID: job.id,
      output: finalOutput,
      now: now
    )
    guard let stableDigest = first.payload?.effectiveLessonSetDigest else {
      throw StoreError.unexpected("reflection fixture evidence has no stable lesson digest")
    }
    let trigger = TriggerIdentity(
      jobID: job.id,
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
    let provider =
      primaryFailure.map { failure in
        SequenceProvider([], then: failure)
      }
      ?? SequenceProvider([response])
    let fallbackProvider = SequenceProvider(primaryFailure == nil ? [] : [response])
    let callIDs = RecordingProviderCallIDGenerator()
    let runnerLearning = RecordingLearningStore(base: learning, admissionFails: admissionFails)
    let roster = ProviderRoster(
      primary: routeBinding(provider: provider, reference: route),
      fallback: primaryFailure == nil
        ? nil : routeBinding(provider: fallbackProvider, reference: fallbackRoute)
    )
    return ReflectionRunEnvironment(
      queue: queue,
      jobs: jobs,
      learning: learning,
      runnerLearning: runnerLearning,
      provider: provider,
      fallbackProvider: fallbackProvider,
      callIDs: callIDs,
      runner: LearningOperationRunner(
        learning: runnerLearning,
        jobs: jobs,
        roster: roster,
        budget: budget(proactivePerDayUSD: proactivePerDayUSD),
        costResolver: CostResolver(
          priceTable: .empty,
          referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
        ),
        redactor: SecretRedactor(secretValues: secretValues),
        providerCallIDGenerator: callIDs,
        logger: logger
      ),
      jobID: job.id,
      trigger: trigger,
      now: now
    )
  }
}

final class RecordingProviderCallIDGenerator: ProviderCallIDGenerating, @unchecked Sendable {
  private let lock = NSLock()
  private var issued = 0

  func next() -> ProviderCallID {
    lock.withLock {
      issued += 1
      return ProviderCallID(rawValue: "reflection-call-\(issued)")
    }
  }

  var count: Int {
    lock.withLock {
      issued
    }
  }
}

// MARK: - Reads and Mutations

extension ReflectionRunEnvironment {
  func operationState() throws -> LearningOperationState? {
    try stringColumn("state").flatMap(LearningOperationState.init(rawValue:))
  }

  func reflectorOperationID() -> LearningOperationID {
    let key = LearningOperationKey(
      jobID: jobID,
      epoch: trigger.epoch,
      phase: .reflector,
      sourceDigest: trigger.digest.rawValue,
      promptVersion: ReflectorPrompt.v1.version,
      schemaVersion: ReflectorOutput.currentSchemaVersion,
      rubricVersion: ReflectorRubric.v1
    )
    return LearningOperationID(key: key.digest, attemptGeneration: 1)
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

  func reflectorOperationCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM learning_operations WHERE phase = ?",
        arguments: [LearningPhase.reflector.rawValue]
      ) ?? -1
    }
  }

  func operationCarrierDigest() throws -> CarrierDigest? {
    try stringColumn("carrier_digest").map(CarrierDigest.init(rawValue:))
  }

  func operationProviderCallID() throws -> ProviderCallID? {
    try stringColumn("provider_call_id").map(ProviderCallID.init(rawValue:))
  }

  func reflectionUsageCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM provider_usage WHERE learning_operation_id = ?",
        arguments: [reflectorOperationID().rawValue]
      ) ?? -1
    }
  }

  func reflectionUsageModel() throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT model FROM provider_usage WHERE learning_operation_id = ?",
        arguments: [reflectorOperationID().rawValue]
      )
    }
  }

  func reflectorLessonSetCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM lesson_sets WHERE source = ?",
        arguments: [LessonSetSource.reflectorCandidate.rawValue]
      ) ?? -1
    }
  }

  func cancelJob() throws {
    guard try jobs.cancel(id: jobID, now: now) != nil else {
      throw StoreError.unexpected("reflection fixture job refused cancellation")
    }
  }

  func learningStateFeedbackRevision(_ revision: FeedbackRevision) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET feedback_revision = ? WHERE job_id = ?",
        arguments: [revision.value, jobID]
      )
    }
  }

  func openLiveTrialWithoutPointer() throws {
    let replacement = try LessonSet.canonical(jobID: jobID, lessons: ["trial lesson"])
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO lesson_sets(job_id, digest, schema_version, \
          canonical_bytes, source, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          jobID,
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
          jobID,
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
          jobID,
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
        arguments: [jobID]
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
          jobID,
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
          jobID,
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
        arguments: [jobID]
      )
    }
    return TriggerIdentity(
      jobID: trigger.jobID,
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
    jobID: Int64,
    output: String,
    now: Date
  ) throws -> SealedEvidence {
    guard case .fired(let fire) = try jobs.fireNow(jobID: jobID, now: now) else {
      throw StoreError.unexpected("reflection fixture job refused to fire")
    }
    _ = try runs.pickUp(runID: fire.runID, now: now)
    try learning.freezeCompatibility(
      runID: fire.runID,
      surface: RunSurface(
        toolCatalogDigest: "tools-v1",
        policyVersion: "pv16",
        skillSetDigest: "skills-v1",
        configuredRoute: route
      )
    )
    _ = try runs.commitAssistantTurn(
      assistantTurn(runID: fire.runID, sessionID: fire.sessionID, output: output),
      now: now
    )
    _ = try learning.sealEvidence(runID: fire.runID, now: now)
    guard let evidence = try learning.evidence(runID: fire.runID) else {
      throw StoreError.unexpected("reflection fixture failed to seal evidence")
    }
    let key = LearningOperationKey(
      jobID: jobID,
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
      operationID: claim.id,
      carrier: CarrierAuthorization(
        sourceDigest: evidence.digest.rawValue,
        digest: CarrierDigest(rawValue: "fixture-\(fire.runID)"),
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
      operationID: claim.id,
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

  static func assistantTurn(runID: Int64, sessionID: Int64, output: String) -> AssistantTurn {
    AssistantTurn(
      runID: runID,
      sessionID: sessionID,
      chatID: 777,
      content: output,
      usage: usageFixture(sessionID: sessionID, runID: runID, model: route),
      chunks: [
        OutboxChunk(
          stepIndex: 0,
          chatID: 777,
          payload: output,
          payloadHash: ContentHash.fnv1a(output)
        ),
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

  static func routeBinding(provider: any LLMProvider, reference: String) -> LLMRouteBinding {
    LLMRouteBinding(
      provider: provider,
      wireModel: reference,
      configuredReference: reference,
      costPolicy: .metered,
      reservationPolicy: .textOnly
    )
  }

  func stringColumn(_ column: String) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT \(column) FROM learning_operations WHERE operation_id = ?",
        arguments: [reflectorOperationID().rawValue]
      )
    }
  }
}
