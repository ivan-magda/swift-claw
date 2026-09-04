import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct LearningViewStoreTests {
  @Test func listUsesOnlyExistingStateWithoutWrites() throws {
    // given
    let fixture = try LearningViewFixture.make()
    let first = try fixture.createJob(label: "first")
    _ = try fixture.createJob(label: "unarmed")
    let third = try fixture.createJob(label: "third")
    _ = try fixture.learning.armJob(jobId: third.id, now: fixture.now)
    _ = try fixture.learning.armJob(jobId: first.id, now: fixture.now)
    let before = try fixture.learningStateCount()

    // when
    let view = try fixture.learning.learningView(jobId: nil)

    // then — driving the list from schedules, or arming while reading, invents learning state.
    #expect(view.count == 2)
    #expect(view.readableJobIds == [first.id, third.id])
    #expect(try fixture.learningStateCount() == before)
  }

  @Test func detailDistinguishesMissingUnarmedAndExactStableSet() throws {
    // given
    let fixture = try LearningViewFixture.make()
    let unarmed = try fixture.createJob(label: "unarmed")
    let armed = try fixture.createJob(label: "armed")
    _ = try fixture.learning.armJob(jobId: armed.id, now: fixture.now)
    let stable = try fixture.installStableLessons(
      ["Keep the first fact.", "Keep the second fact."],
      jobId: armed.id
    )

    // when
    let missingView = try fixture.learning.learningView(jobId: 9_999)
    let unarmedView = try fixture.learning.learningView(jobId: unarmed.id)
    let armedView = try fixture.learning.learningView(jobId: armed.id)

    // then — substituting an empty/newest set erases the requested pointer's exact state.
    #expect(missingView == [.notFound(jobId: 9_999)])
    #expect(unarmedView == [.unarmed(fixture.identity(for: unarmed))])
    let readable = try #require(armedView.onlyReadable)
    #expect(readable.stableLessons == stable)
    #expect(readable.stableRevision == StableRevision(7))
  }

  @Test(arguments: LiveTrialCorruption.allCases)
  func liveTrialRejectsMultiplicityAndUsesExactIdentity(
    _ corruption: LiveTrialCorruption
  ) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
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
      try fixture.env.learning.learningView(jobId: fixture.env.jobId).onlyReadable
    )
    let trial = try #require(baseline.liveTrial)
    #expect(trial.candidateDigest == artifact.digest)
    #expect(trial.baseDigest == artifact.manifest.baseDigest)
    #expect(trial.replacementDigest == artifact.replacement.digest)
    #expect(trial.counts == LearningTrialCounts(consumed: 1, maximum: 3, unresolved: 1))
    guard case .candidateAdmission(let inputs, let decisionReceipt) = baseline.lastDecision?.detail
    else {
      Issue.record("expected the typed admission receipt")
      return
    }
    #expect(inputs.candidateDigest == artifact.digest)
    #expect(decisionReceipt == receipt)
    try fixture.corruptViewTrial(corruption, trialId: receipt.trialId)

    // when
    let view = try fixture.env.learning.learningView(jobId: fixture.env.jobId)

    // then — following the convenience pointer or omitting assignment identity hides corruption.
    #expect(view.isOnlyUnreadable)
  }

  @Test func lastDecisionIsTypedCurrentEpochAndUsesTheStableTieBreak() throws {
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
    let current = try #require(try env.learning.learningView(jobId: env.jobId).onlyReadable)

    // then — dropping the epoch predicate lets a newer receipt from another epoch win.
    guard case .reflectionNoCandidate(let inputs, let result) = current.lastDecision?.detail else {
      Issue.record("expected the typed no-candidate receipt")
      return
    }
    #expect(inputs.operationId == operation.id)
    #expect(result.resultDigest == noCandidate.resultDigest)

    // when
    try env.insertMalformedTiedCurrentDecision(decidedAt: env.now)
    let corrupt = try env.learning.learningView(jobId: env.jobId)

    // then — omitting decision_id from the tie break can hide the latest malformed receipt.
    #expect(corrupt.isOnlyUnreadable)
  }
}

enum LiveTrialCorruption: CaseIterable, Sendable {
  case secondLiveTrial
  case assignmentEpoch
  case assignmentGeneration
}

private extension Array where Element == JobLearningView {
  var readableJobIds: [Int64] {
    compactMap { item in
      guard case .readable(let view) = item else {
        return nil
      }
      return view.job.jobId
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
}

private struct LearningViewFixture {
  let queue: DatabaseQueue
  let jobs: ScheduledJobStoreGRDB
  let learning: ScheduledLearningStoreGRDB
  let now = Date(timeIntervalSince1970: 1_782_000_600)

  static func make() throws -> LearningViewFixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return LearningViewFixture(
      queue: queue,
      jobs: ScheduledJobStoreGRDB(writer: queue, learningEnabled: false),
      learning: ScheduledLearningStoreGRDB(writer: queue)
    )
  }

  func createJob(label: String) throws -> ScheduledJob {
    try jobs.create(
      NewScheduledJob(
        ownerChatId: 777,
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
    LearningJobIdentity(
      jobId: job.id,
      label: job.label,
      status: job.status,
      timezone: job.timezone
    )
  }

  func learningStateCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job_learning_state") ?? -1
    }
  }

  func installStableLessons(_ lessons: [String], jobId: Int64) throws -> LessonSet {
    let set = try LessonSet.canonical(jobId: jobId, lessons: lessons)
    let decoy = try LessonSet.canonical(jobId: jobId, lessons: ["Do not select the newest set."])
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
            created_at) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          jobId,
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
        arguments: [set.digest.rawValue, jobId]
      )
      try db.execute(
        sql: """
          INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
            created_at) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          jobId,
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
}

private extension AdmissionStoreFixture {
  func corruptViewTrial(
    _ corruption: LiveTrialCorruption,
    trialId: Int64
  ) throws {
    try env.queue.write { db in
      switch corruption {
      case .secondLiveTrial:
        try db.execute(
          sql: """
            INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
              generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
              consumed_assignments, cohort_cutoff, state, algorithm)
            SELECT job_id, learning_epoch, base_digest, candidate_digest, generation + 1,
              admitted_at, assignment_deadline, decision_deadline, max_assignments, 0,
              cohort_cutoff, ?, algorithm
            FROM learning_trials WHERE trial_id = ?
            """,
          arguments: [LearningTrialState.draining.rawValue, trialId]
        )
      case .assignmentEpoch:
        try db.execute(
          sql:
            "UPDATE trial_assignments SET learning_epoch = learning_epoch + 1 WHERE trial_id = ?",
          arguments: [trialId]
        )
      case .assignmentGeneration:
        try db.execute(
          sql: "UPDATE trial_assignments SET trial_generation = 99 WHERE trial_id = ?",
          arguments: [trialId]
        )
      }
    }
  }
}

private extension BoundRunEnvironment {
  func insertNonCurrentDecision(decidedAt: Date) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_decisions(kind, job_id, learning_epoch, inputs, result, algorithm,
            decided_at) VALUES ('unknown', ?, 0, '{}', '{}', ?, ?)
          """,
        arguments: [jobId, LearningAlgorithm.v1.rawValue, EpochSecondCodec.epoch(decidedAt)]
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
          jobId,
          LearningAlgorithm.v1.rawValue,
          EpochSecondCodec.epoch(decidedAt),
        ]
      )
    }
  }
}
