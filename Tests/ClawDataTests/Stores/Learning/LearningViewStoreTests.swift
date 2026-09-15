import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct LearningViewStoreTests {
  @Test
  func listUsesOnlyExistingStateWithoutWrites() throws {
    // given
    let fixture = try LearningViewFixture.make()
    let first = try fixture.createJob(label: "first")
    _ = try fixture.createJob(label: "unarmed")
    let third = try fixture.createJob(label: "third")
    _ = try TestLearningFixtures(writer: fixture.queue).seedArmedJob(
      jobID: third.id,
      now: fixture.now
    )
    _ = try TestLearningFixtures(writer: fixture.queue).seedArmedJob(
      jobID: first.id,
      now: fixture.now
    )
    let before = try fixture.learningStateCount()

    // when
    let view = try fixture.learning.learningView(jobID: nil)

    // then — driving the list from schedules, or arming while reading, invents learning state.
    #expect(view.count == 2)
    #expect(view.readableJobIDs == [first.id, third.id])
    #expect(try fixture.learningStateCount() == before)
  }

  @Test
  func detailDistinguishesMissingUnarmedAndExactStableSet() throws {
    // given
    let fixture = try LearningViewFixture.make()
    let unarmed = try fixture.createJob(label: "unarmed")
    let armed = try fixture.createJob(label: "armed")
    _ = try TestLearningFixtures(writer: fixture.queue).seedArmedJob(
      jobID: armed.id,
      now: fixture.now
    )
    let stable = try fixture.installStableLessons(
      ["Keep the first fact.", "Keep the second fact."],
      jobID: armed.id
    )

    // when
    let missingView = try fixture.learning.learningView(jobID: 9_999)
    let unarmedView = try fixture.learning.learningView(jobID: unarmed.id)
    let armedView = try fixture.learning.learningView(jobID: armed.id)

    // then — substituting an empty/newest set erases the requested pointer's exact state.
    #expect(missingView == [.notFound(jobID: 9_999)])
    #expect(unarmedView == [.unarmed(fixture.identity(for: unarmed))])
    let readable = try #require(armedView.onlyReadable)
    #expect(readable.stableLessons == stable)
    #expect(readable.stableRevision == StableRevision(7))
  }

  @Test(arguments: StableViewCorruption.allCases)
  func stableStateTrustBoundariesFailClosed(_ corruption: StableViewCorruption) throws {
    // given
    let fixture = try LearningViewFixture.make()
    let job = try fixture.createJob(label: "damaged stable state")
    _ = try TestLearningFixtures(writer: fixture.queue).seedArmedJob(
      jobID: job.id,
      now: fixture.now
    )
    try fixture.applyStableCorruption(corruption, jobID: job.id)

    // when
    let view = try fixture.learning.learningView(jobID: job.id)

    // then — substituting a missing, foreign, noncanonical, digest-mismatched set, or malformed
    // job identity would survive the positive exact-set test for correctly stored rows.
    #expect(view.isOnlyUnreadable)
  }

  @Test
  func listKeepsHealthyJobsBesideUnreadableJobs() throws {
    // given
    let fixture = try LearningViewFixture.make()
    let healthy = try fixture.createJob(label: "healthy")
    let damaged = try fixture.createJob(label: "damaged")
    _ = try TestLearningFixtures(writer: fixture.queue).seedArmedJob(
      jobID: healthy.id,
      now: fixture.now
    )
    _ = try TestLearningFixtures(writer: fixture.queue).seedArmedJob(
      jobID: damaged.id,
      now: fixture.now
    )
    try fixture.invalidateTimezone(jobID: damaged.id)

    // when
    let view = try fixture.learning.learningView(jobID: nil)

    // then — failing the whole list on one semantic row would hide the preceding healthy job;
    // the nearest list test has no corrupt state to exercise per-job isolation.
    #expect(view.count == 2)
    #expect(view.readableJobIDs == [healthy.id])
    #expect(view.unreadableJobIDs == [damaged.id])
  }

  @Test
  func operationalReadFailureLeavesThroughTheStoreSeam() throws {
    // given
    let fixture = try LearningViewFixture.make()
    let job = try fixture.createJob(label: "operational failure")
    _ = try TestLearningFixtures(writer: fixture.queue).seedArmedJob(
      jobID: job.id,
      now: fixture.now
    )
    try fixture.queue.write { db in
      try db.drop(table: "job_learning_state")
    }

    // when
    do {
      _ = try fixture.learning.learningView(jobID: job.id)
      Issue.record("expected a mapped store failure")
    } catch let error {
      // then — catching all read errors as row corruption would return unreadable and acknowledge
      // a retryable database failure; the group refusal test never reaches its dropped table.
      guard case .unexpected = error else {
        Issue.record("expected StoreError.unexpected, got \(error)")
        return
      }
    }
  }

  @Test(arguments: LiveTrialCorruption.allCases)
  func liveTrialRejectsMultiplicityAndUsesExactIdentity(_ corruption: LiveTrialCorruption) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let admitted = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    guard case .admitted(let receipt) = admitted else {
      Issue.record("expected fixture candidate admission")
      return
    }
    _ = try fixture.env.pendingBoundRun()
    let baseline = try #require(
      try fixture.env.learning.learningView(jobID: fixture.env.jobID).onlyReadable
    )
    let trial = try #require(baseline.liveTrial)
    #expect(trial.candidateDigest == artifact.digest)
    #expect(trial.baseDigest == artifact.manifest.baseDigest)
    #expect(trial.replacementDigest == artifact.replacement.digest)
    #expect(
      trial.counts
        == LearningTrialCounts(
          consumed: 1,
          maximum: 3,
          positive: 0,
          negative: 0,
          neutral: 0,
          unresolved: 1
        )
    )
    guard case .candidateAdmission(let inputs, let decisionReceipt) = baseline.lastDecision?.detail
    else {
      Issue.record("expected the typed admission receipt")
      return
    }
    #expect(inputs.candidateDigest == artifact.digest)
    #expect(decisionReceipt == receipt)
    try fixture.corruptViewTrial(corruption, artifact: artifact, trialID: receipt.trialID)

    // when
    let view = try fixture.env.learning.learningView(jobID: fixture.env.jobID)

    // then — following the convenience pointer or omitting assignment identity hides corruption.
    #expect(view.isOnlyUnreadable)
  }

  @Test
  func liveTrialCountsAuthoritativeFourWayOutcomesWithoutWriting() throws {
    // given
    let env = try BoundRunEnvironment.make()
    try env.makeRepeatable()
    try env.installTrial()
    let verdicts = [
      env.verdict(outcome: .noIssue, issueCodes: []),
      env.verdict(outcome: .reusableIssue, issueCodes: ["wrong_fact"]),
      env.verdict(outcome: .transientIssue, issueCodes: []),
    ]
    var operations: [ClaimedOperation] = []
    for _ in verdicts {
      let evidence = try env.sealedTrialEvidence()
      operations.append(try env.startedOperation(env.evaluatorKey(for: evidence)))
    }
    for (operation, verdict) in zip(operations, verdicts) {
      _ = try env.learning.finishOperation(
        env.result(for: operation.id, evaluation: verdict),
        now: env.now
      )
    }
    let identities = try env.learning.liveTrialIdentities()
    #expect(identities.count == 1)
    let identity = try #require(identities.first)
    _ = try env.learning.reconcileTrial(identity, now: env.now)
    let before = try env.trialAssignmentSnapshot()

    // when
    let view = try #require(try env.learning.learningView(jobID: env.jobID).onlyReadable)
    let after = try env.trialAssignmentSnapshot()

    // then — counting cache state or mutating it during the read would survive the unresolved-only
    // fixture because every stored and derived row agrees there.
    #expect(after == before)
    #expect(
      view.liveTrial?.counts
        == LearningTrialCounts(
          consumed: 3,
          maximum: 3,
          positive: 1,
          negative: 1,
          neutral: 1,
          unresolved: 0
        )
    )
  }

  @Test
  func liveTrialViewDerivesAResolvedOutcomeFromSourcesDespiteLaggingCache() throws {
    // given
    let env = try BoundRunEnvironment.make()
    try env.makeRepeatable()
    try env.installTrial()
    let evidence = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: evidence))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    try env.resetAssignmentCache(runID: evidence.runID, state: .learningOutcomeUnresolved)
    let before = try env.trialAssignmentSnapshot()

    // when
    let view = try #require(try env.learning.learningView(jobID: env.jobID).onlyReadable)
    let after = try env.trialAssignmentSnapshot()

    // then — the cache says unresolved, but the succeeded exact evaluation says positive.
    #expect(after == before)
    #expect(
      view.liveTrial?.counts
        == LearningTrialCounts(
          consumed: 1,
          maximum: 3,
          positive: 1,
          negative: 0,
          neutral: 0,
          unresolved: 0
        )
    )
  }

  @Test
  func liveTrialViewUsesNewerFeedbackWithoutRepairingTheCache() throws {
    // given
    let env = try BoundRunEnvironment.make()
    try env.makeRepeatable()
    try env.installTrial()
    let evidence = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: evidence))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    _ = try env.appendFeedback(
      subjectKind: .run,
      subjectDigest: String(evidence.runID),
      signal: .resultNotUseful
    )
    let before = try env.trialAssignmentSnapshot()

    // when
    let view = try #require(try env.learning.learningView(jobID: env.jobID).onlyReadable)
    let after = try env.trialAssignmentSnapshot()

    // then — reading cached positive would hide the newer current owner verdict.
    #expect(after == before)
    #expect(
      view.liveTrial?.counts
        == LearningTrialCounts(
          consumed: 1,
          maximum: 3,
          positive: 0,
          negative: 1,
          neutral: 0,
          unresolved: 0
        )
    )
  }

  @Test
  func liveTrialViewRejectsAResolvedCacheWithoutItsAuthoritativeEvaluation() throws {
    // given
    let env = try BoundRunEnvironment.make()
    try env.makeRepeatable()
    try env.installTrial()
    let evidence = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: evidence))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE learning_operations SET key_digest = ? WHERE operation_id = ?",
        arguments: [String(repeating: "f", count: 64), operation.id.rawValue]
      )
    }
    let before = try env.trialAssignmentSnapshot()

    // when
    let view = try env.learning.learningView(jobID: env.jobID)
    let after = try env.trialAssignmentSnapshot()

    // then — guessing from the cached outcome would expose unsupported quality evidence.
    #expect(view.isOnlyUnreadable)
    #expect(after == before)
  }

  @Test(arguments: LiveWorkflowMutation.allCases)
  func liveWorkflowStatusAndPointerStayReadOnly(_ mutation: LiveWorkflowMutation) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let admitted = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    guard case .admitted(let receipt) = admitted else {
      Issue.record("expected fixture candidate admission")
      return
    }
    try fixture.applyLiveWorkflowMutation(mutation, trialID: receipt.trialID)
    let before = try fixture.durableLearningSnapshot()

    // when
    let detail = try fixture.env.learning.learningView(jobID: fixture.env.jobID)
    let list = try fixture.env.learning.learningView(jobID: nil)
    let after = try fixture.durableLearningSnapshot()

    // then — admitting a cancelled job's stale trial or repairing the pointer during a read would
    // survive the positive live-trial test; its nearest tests never snapshot all touched domains.
    #expect(after == before)
    switch mutation {
    case .cancelledJob:
      #expect(detail.isOnlyUnreadable)
      #expect(list.isOnlyUnreadable)
    case .stalePointer:
      let detailed = try #require(detail.onlyReadable)
      let listed = try #require(list.onlyReadable)
      #expect(detailed.liveTrial?.trialID == receipt.trialID)
      #expect(detailed.warnings == [.trialPointerMismatch])
      #expect(listed.liveTrial?.trialID == receipt.trialID)
      #expect(listed.warnings == [.trialPointerMismatch])
    }
  }

  @Test
  func lastDecisionIsTypedCurrentEpochAndUsesTheStableTieBreak() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let reflection = try env.reflectionFixture()
    let operation = try env.startReflector(reflection)
    let noCandidate = try env.noCandidate(fixture: reflection, operation: operation)
    _ = try env.learning.finishOperation(
      env.reflectionResult(operation: operation, product: .noCandidate(noCandidate)),
      now: env.now
    )
    try env.insertNonCurrentDecision(decidedAt: env.now.addingTimeInterval(60))

    // when
    let current = try #require(try env.learning.learningView(jobID: env.jobID).onlyReadable)

    // then — dropping the epoch predicate lets a newer receipt from another epoch win.
    guard case .reflectionNoCandidate(let inputs, let result) = current.lastDecision?.detail else {
      Issue.record("expected the typed no-candidate receipt")
      return
    }
    #expect(inputs.operationID == operation.id)
    #expect(result.resultDigest == noCandidate.resultDigest)

    // when
    try env.insertMalformedTiedCurrentDecision(decidedAt: env.now)
    let corrupt = try env.learning.learningView(jobID: env.jobID)

    // then — omitting decision_id from the tie break can hide the latest malformed receipt.
    #expect(corrupt.isOnlyUnreadable)
  }

  @Test(arguments: CurrentDecisionCorruption.allCases)
  func currentDecisionTrustBoundariesFailClosed(_ corruption: CurrentDecisionCorruption) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let admitted = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    guard case .admitted(let receipt) = admitted else {
      Issue.record("expected fixture candidate admission")
      return
    }
    try fixture.closeTrialForDecisionView(trialID: receipt.trialID)
    try fixture.corruptCurrentDecision(corruption, receipt: receipt)

    // when
    let view = try fixture.env.learning.learningView(jobID: fixture.env.jobID)

    // then — treating an unknown kind as absent or trusting receipt fields without their durable
    // identity would survive the current-epoch ordering test's otherwise valid receipt.
    #expect(view.isOnlyUnreadable)
  }

  @Test(arguments: ViewPrimitiveCorruption.allCases)
  func incompatibleStoredPrimitivesArePerJobUnreadable(_ corruption: ViewPrimitiveCorruption) throws
  {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let admitted = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    guard case .admitted(let receipt) = admitted else {
      Issue.record("expected fixture candidate admission")
      return
    }
    _ = try fixture.env.pendingBoundRun()
    try fixture.corruptStoredPrimitive(corruption, trialID: receipt.trialID)

    // when
    let view = try fixture.env.learning.learningView(jobID: fixture.env.jobID)

    // then — a non-optional typed Row subscript can abort instead of isolating a bad job;
    // existing semantic tests keep the expected SQLite storage classes and cannot kill it.
    #expect(view.isOnlyUnreadable)
  }

  @Test
  func wrongClassNullableJobFieldIsPerJobUnreadable() throws {
    // given
    let fixture = try LearningViewFixture.make()
    let job = try fixture.createJob(label: "wrong nullable class")
    _ = try TestLearningFixtures(writer: fixture.queue).seedArmedJob(
      jobID: job.id,
      now: fixture.now
    )
    try fixture.storeBlobAsRecurrence(jobID: job.id)

    // when
    let view = try fixture.learning.learningView(jobID: job.id)

    // then — accepting a wrong-class nullable value as SQL NULL makes this job readable; the
    // nearest primitive matrix reaches only non-optional fields.
    #expect(view.isOnlyUnreadable)
  }

  @Test
  func outOfDomainAssignmentBooleanIsPerJobUnreadable() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let admitted = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    guard case .admitted(let receipt) = admitted else {
      Issue.record("expected fixture candidate admission")
      return
    }
    _ = try fixture.env.pendingBoundRun()
    try fixture.storeOutOfDomainEvaluationRequired(trialID: receipt.trialID)

    // when
    let view = try fixture.env.learning.learningView(jobID: fixture.env.jobID)

    // then — treating every nonzero INTEGER as true accepts the damaged assignment; the nearest
    // primitive matrix changes an integer's storage class and never tests the Boolean domain.
    #expect(view.isOnlyUnreadable)
  }
}

enum LiveTrialCorruption: CaseIterable, Sendable {
  case secondLiveTrial
  case assignmentEpoch
  case assignmentGeneration
}

enum LiveWorkflowMutation: CaseIterable, Sendable {
  case cancelledJob
  case stalePointer
}

enum StableViewCorruption: CaseIterable, Sendable {
  case missingSet
  case crossJobSet
  case noncanonicalSet
  case digestMismatch
  case invalidJobMetadata
}

enum CurrentDecisionCorruption: CaseIterable, Sendable {
  case unknownKind
  case receiptIdentity
}

enum ViewPrimitiveCorruption: CaseIterable, Sendable {
  case job
  case state
  case trial
  case assignment
  case decision
}

// MARK: - Learning View Inspection

private extension Array where Element == JobLearningView {
  var readableJobIDs: [Int64] {
    compactMap { item in
      guard case .readable(let view) = item else {
        return nil
      }
      return view.job.jobID
    }
  }

  var onlyReadable: ReadableJobLearningView? {
    guard count == 1, case .readable(let view) = self[0] else {
      return nil
    }
    return view
  }

  var isOnlyUnreadable: Bool {
    guard count == 1, case .unreadable = self[0] else {
      return false
    }
    return true
  }

  var unreadableJobIDs: [Int64] {
    compactMap { item in
      guard case .unreadable(let job) = item else {
        return nil
      }
      return job.jobID
    }
  }
}

private struct LearningViewFixture {
  let queue: DatabaseQueue
  let jobs: ScheduledJobStoreGRDB
  let learning: ScheduledLearningStoreGRDB
  let now = Date(timeIntervalSince1970: 1_782_000_600)

  static func make() throws -> LearningViewFixture {
    let queue = try TestDatabase.make()
    return LearningViewFixture(
      queue: queue,
      jobs: ScheduledJobStoreGRDB(writer: queue, learningEnabled: false),
      learning: ScheduledLearningStoreGRDB(writer: queue)
    )
  }

  func createJob(label: String) throws -> ScheduledJob {
    try jobs.create(
      NewScheduledJob(
        ownerChatID: 777,
        label: label,
        prompt: "Summarize",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
  }

  func identity(for job: ScheduledJob) -> LearningJobIdentity {
    LearningJobIdentity(jobID: job.id, label: job.label, status: job.status, timezone: job.timezone)
  }

  func learningStateCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job_learning_state") ?? -1
    }
  }

  func installStableLessons(_ lessons: [String], jobID: Int64) throws -> LessonSet {
    let set = try LessonSet.canonical(jobID: jobID, lessons: lessons)
    let decoy = try LessonSet.canonical(jobID: jobID, lessons: ["Do not select the newest set."])
    try queue.write { db in
      try db.execute(
        sql: """
        INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
          created_at) VALUES (?, ?, ?, ?, ?, ?)
        """,
        arguments: [
          jobID,
          set.digest.rawValue,
          set.schemaVersion,
          set.canonicalBytes,
          LessonSetSource.reflectorCandidate.rawValue,
          EpochSecondCodec.epoch(now),
        ]
      )
      try db.execute(
        sql: """
        UPDATE job_learning_state
        SET stable_lesson_set_digest = ?, stable_revision = 7
        WHERE job_id = ?
        """,
        arguments: [set.digest.rawValue, jobID]
      )
      try db.execute(
        sql: """
        INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
          created_at) VALUES (?, ?, ?, ?, ?, ?)
        """,
        arguments: [
          jobID,
          decoy.digest.rawValue,
          decoy.schemaVersion,
          decoy.canonicalBytes,
          LessonSetSource.reflectorCandidate.rawValue,
          EpochSecondCodec.epoch(now.addingTimeInterval(60)),
        ]
      )
    }
    return set
  }

  func applyStableCorruption(_ corruption: StableViewCorruption, jobID: Int64) throws {
    switch corruption {
    case .missingSet: try pointStableState(jobID: jobID, digest: String(repeating: "d", count: 64))
    case .crossJobSet:
      let other = try createJob(label: "foreign stable owner")
      _ = try TestLearningFixtures(writer: queue).seedArmedJob(jobID: other.id, now: now)
      let foreign = try installStableLessons(["Only the other job owns this."], jobID: other.id)
      try pointStableState(jobID: jobID, digest: foreign.digest.rawValue)
    case .noncanonicalSet: try replaceStableBytes(jobID: jobID, bytes: Data("{".utf8))
    case .digestMismatch:
      let different = try LessonSet.canonical(jobID: jobID, lessons: ["Different bytes."])
      try replaceStableBytes(jobID: jobID, bytes: different.canonicalBytes)
    case .invalidJobMetadata: try invalidateTimezone(jobID: jobID)
    }
  }

  func invalidateTimezone(jobID: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE scheduled_jobs SET timezone = 'not/a-zone' WHERE id = ?",
        arguments: [jobID]
      )
    }
  }

  func storeBlobAsRecurrence(jobID: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE scheduled_jobs SET recurrence = ? WHERE id = ?",
        arguments: [Data([0xFF]), jobID]
      )
    }
  }

  private func pointStableState(jobID: Int64, digest: String) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET stable_lesson_set_digest = ? WHERE job_id = ?",
        arguments: [digest, jobID]
      )
    }
  }

  private func replaceStableBytes(jobID: Int64, bytes: Data) throws {
    try queue.write { db in
      try db.execute(
        sql: """
        UPDATE lesson_sets SET canonical_bytes = ?
        WHERE job_id = ? AND digest = (
          SELECT stable_lesson_set_digest FROM job_learning_state WHERE job_id = ?
        )
        """,
        arguments: [bytes, jobID, jobID]
      )
    }
  }
}

// MARK: - Learning View Corruption Fixtures

private extension AdmissionStoreFixture {
  func storeOutOfDomainEvaluationRequired(trialID: Int64) throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE trial_assignments SET evaluation_required = 2 WHERE trial_id = ?",
        arguments: [trialID]
      )
    }
  }

  func corruptViewTrial(
    _ corruption: LiveTrialCorruption,
    artifact: CandidateArtifact,
    trialID: Int64
  ) throws {
    let sql: String
    switch corruption {
    case .secondLiveTrial:
      try env.queue.write { db in
        try db.execute(sql: "DROP INDEX idx_learning_trials_live_job")
      }
      try insertCompetingDrainingTrial(from: artifact)
      return
    case .assignmentEpoch:
      sql = "UPDATE trial_assignments SET learning_epoch = learning_epoch + 1 WHERE trial_id = ?"
    case .assignmentGeneration:
      sql = "UPDATE trial_assignments SET trial_generation = 99 WHERE trial_id = ?"
    }
    try env.queue.write { db in
      try db.execute(sql: sql, arguments: [trialID])
    }
  }

  func applyLiveWorkflowMutation(_ mutation: LiveWorkflowMutation, trialID: Int64) throws {
    switch mutation {
    case .cancelledJob: try env.cancelJob()
    case .stalePointer:
      try env.queue.write { db in
        try db.execute(
          sql: "UPDATE job_learning_state SET open_trial_id = ? WHERE job_id = ?",
          arguments: [trialID + 10_000, env.jobID]
        )
      }
    }
  }

  func durableLearningSnapshot() throws -> DurableLearningSnapshot {
    let tableNames = [
      "scheduled_jobs",
      "job_learning_state",
      "lesson_sets",
      "learning_candidates",
      "learning_trials",
      "trial_assignments",
      "learning_decisions",
      "audit_events",
      "feedback_targets",
      "outbound_deliveries",
    ]
    return try env.queue.read { db in
      let tables = try tableNames.map { tableName in
        let columnRows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
        let columns = columnRows.map { row in
          row["name"] as String
        }
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(tableName) ORDER BY rowid")
        let values = rows.map { row in
          columns.map { column in
            row[column] as DatabaseValue
          }
        }
        return DurableTableSnapshot(name: tableName, columns: columns, rows: values)
      }
      return DurableLearningSnapshot(tables: tables)
    }
  }

  func corruptCurrentDecision(_ corruption: CurrentDecisionCorruption, receipt: AdmissionReceipt)
    throws
  {
    try env.queue.write { db in
      switch corruption {
      case .unknownKind:
        try db.execute(sql: "UPDATE learning_decisions SET kind = 'unknown' WHERE decision_id = 1")
      case .receiptIdentity:
        let altered = AdmissionReceipt(
          candidateDigest: receipt.candidateDigest,
          replacementDigest: receipt.replacementDigest,
          trialID: receipt.trialID,
          generation: receipt.generation + 1
        )
        let bytes = try CanonicalJSON.data(encoding: altered)
        guard let result = String(bytes: bytes, encoding: .utf8) else {
          throw StoreError.unexpected("fixture receipt was not UTF-8")
        }
        try db.execute(
          sql: "UPDATE learning_decisions SET result = ? WHERE decision_id = 1",
          arguments: [result]
        )
      }
    }
  }

  func closeTrialForDecisionView(trialID: Int64) throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE learning_trials SET state = ?, close_reason = ? WHERE trial_id = ?",
        arguments: [LearningTrialState.closed.rawValue, "fixture close", trialID]
      )
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = NULL WHERE job_id = ?",
        arguments: [env.jobID]
      )
    }
  }

  func corruptStoredPrimitive(_ corruption: ViewPrimitiveCorruption, trialID: Int64) throws {
    let invalid = Data([0xFF])
    try env.queue.write { db in
      switch corruption {
      case .job:
        try db.execute(
          sql: "UPDATE scheduled_jobs SET timezone = ? WHERE id = ?",
          arguments: [invalid, env.jobID]
        )
      case .state:
        try db.execute(
          sql: "UPDATE job_learning_state SET learning_epoch = ? WHERE job_id = ?",
          arguments: [invalid, env.jobID]
        )
      case .trial:
        try db.execute(
          sql: "UPDATE learning_trials SET generation = ? WHERE trial_id = ?",
          arguments: [invalid, trialID]
        )
      case .assignment:
        try db.execute(
          sql: "UPDATE trial_assignments SET trial_generation = ? WHERE trial_id = ?",
          arguments: [invalid, trialID]
        )
      case .decision:
        try db.execute(
          sql: "UPDATE learning_decisions SET decided_at = ? WHERE decision_id = 1",
          arguments: [invalid]
        )
      }
    }
  }
}

private struct DurableLearningSnapshot: Equatable { let tables: [DurableTableSnapshot] }

private struct DurableTableSnapshot: Equatable {
  let name: String
  let columns: [String]
  let rows: [[DatabaseValue]]
}

// MARK: - Decision Projection Fixtures

private extension BoundRunEnvironment {
  func trialAssignmentSnapshot() throws -> [[DatabaseValue]] {
    try queue.read { db in
      let columns = try String.fetchAll(
        db,
        sql: "SELECT name FROM pragma_table_info('trial_assignments') ORDER BY cid"
      )
      let rows = try Row.fetchAll(db, sql: "SELECT * FROM trial_assignments ORDER BY run_id")
      return rows.map { row in
        columns.map { column in
          row[column] as DatabaseValue
        }
      }
    }
  }

  func insertNonCurrentDecision(decidedAt: Date) throws {
    try queue.write { db in
      try db.execute(
        sql: """
        INSERT INTO learning_decisions(kind, job_id, learning_epoch, inputs, result, algorithm,
          decided_at) VALUES ('unknown', ?, 0, '{}', '{}', ?, ?)
        """,
        arguments: [jobID, LearningAlgorithm.v1.rawValue, EpochSecondCodec.epoch(decidedAt)]
      )
    }
  }

  func insertMalformedTiedCurrentDecision(decidedAt: Date) throws {
    try queue.write { db in
      try db.execute(
        sql: """
        INSERT INTO learning_decisions(kind, job_id, learning_epoch, inputs, result, algorithm,
          decided_at) VALUES (?, ?, 1, '{}', '{}', ?, ?)
        """,
        arguments: [
          ReflectionNoCandidateReceipt.kind,
          jobID,
          LearningAlgorithm.v1.rawValue,
          EpochSecondCodec.epoch(decidedAt),
        ]
      )
    }
  }
}
