import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData
@testable import ClawGateway

@Suite struct TrialSweepTests {
  @Test func periodicSweepDrainsPausedTrialAndReturnsDeadlineRecommendation() async throws {
    // given
    let fixture = try TrialSweepFixture.make()
    let service = ScheduledLearningService(
      store: fixture.learning,
      logger: TestLog.silent
    )

    // when
    let first = await service.reconcileTrials(now: fixture.assignmentDeadline)
    let second = await service.reconcileTrials(now: fixture.assignmentDeadline)

    // then — a future fire is not required to close exposure, and retry does not drain twice.
    #expect(first.count == 1)
    #expect(first.first?.identity == fixture.identity)
    #expect(first.first?.didDrain == true)
    #expect(first.first?.decision == .fallback(reason: .insufficientSupport))
    #expect(second.count == 1)
    #expect(second.first?.didDrain == false)
    #expect(second.first?.decision == .fallback(reason: .insufficientSupport))
    #expect(try fixture.trialState() == .draining)
  }

  @Test func periodicAndBootPassesKeepExactSealingAndOperationOrder() async throws {
    // given
    let base = try emptyStore()
    let identity = trialIdentity(id: 11, jobId: 4)
    let reconciliation = TrialReconciliation(
      identity: identity,
      didDrain: false,
      assignments: [],
      decision: .wait
    )
    let behavior = RecordingLearningStore.ServiceBehavior(
      identities: [identity],
      trialResults: [identity.trialId: .reconciled(reconciliation)],
      unsealedRunIds: [91],
      handledSealRunIds: [91]
    )
    let recording = RecordingLearningStore(base: base, serviceBehavior: behavior)
    let service = ScheduledLearningService(store: recording, logger: TestLog.silent)

    // when
    await service.sweep(now: Date(timeIntervalSince1970: 10))

    // then — enumerating before sealing can reconcile a source snapshot the same pass changes.
    #expect(recording.serviceCalls == ["unsealed", "seal:91", "live", "trial:11"])

    // when
    recording.clearServiceCalls()
    recording.failBootReconciliation = true
    await service.reconcileAtBoot(now: Date(timeIntervalSince1970: 11))
    await service.sweep(now: Date(timeIntervalSince1970: 11))

    // then — operation failure is isolated; the runtime sweep still seals before its trial pass.
    #expect(
      recording.serviceCalls
        == ["operations", "unsealed", "seal:91", "live", "trial:11"]
    )
  }

  @Test func oneTrialFailureDoesNotBlockLaterTrialsAndStaleIsDropped() async throws {
    // given
    let base = try emptyStore()
    let first = trialIdentity(id: 21, jobId: 5)
    let stale = trialIdentity(id: 22, jobId: 6)
    let last = trialIdentity(id: 23, jobId: 7)
    let expected = TrialReconciliation(
      identity: last,
      didDrain: false,
      assignments: [],
      decision: .wait
    )
    let behavior = RecordingLearningStore.ServiceBehavior(
      identities: [first, stale, last],
      trialResults: [
        stale.trialId: .stale,
        last.trialId: .reconciled(expected),
      ],
      failingTrialIds: [first.trialId]
    )
    let recording = RecordingLearningStore(base: base, serviceBehavior: behavior)
    let service = ScheduledLearningService(store: recording, logger: TestLog.silent)

    // when
    let results = await service.reconcileTrials(now: Date(timeIntervalSince1970: 12))

    // then — aborting on the first mapped error loses the healthy later trial.
    #expect(results == [expected])
    #expect(recording.serviceCalls == ["live", "trial:21", "trial:22", "trial:23"])
  }

  @Test func trialEnumerationFailureReturnsEmptyWithoutAttemptingAnIdentity() async throws {
    // given
    let recording = RecordingLearningStore(
      base: try emptyStore(),
      serviceBehavior: RecordingLearningStore.ServiceBehavior(failEnumeration: true)
    )
    let service = ScheduledLearningService(store: recording, logger: TestLog.silent)

    // when
    let results = await service.reconcileTrials(now: Date(timeIntervalSince1970: 13))

    // then — guessed identities after an unreadable live set could cross job or epoch boundaries.
    #expect(results.isEmpty)
    #expect(recording.serviceCalls == ["live"])
  }
}

// MARK: - Fixtures

private extension TrialSweepTests {
  func emptyStore() throws -> ScheduledLearningStoreGRDB {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return ScheduledLearningStoreGRDB(writer: queue)
  }

  func trialIdentity(id: Int64, jobId: Int64) -> LearningTrialIdentity {
    LearningTrialIdentity(
      trialId: id,
      jobId: jobId,
      epoch: LearningEpoch(1),
      generation: 1
    )
  }
}

private struct TrialSweepFixture {
  let queue: DatabaseQueue
  let learning: ScheduledLearningStoreGRDB
  let identity: LearningTrialIdentity
  let assignmentDeadline: Date

  static func make() throws -> TrialSweepFixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let deadline = Date(timeIntervalSince1970: 1_782_086_400)
    let admittedAt = deadline.addingTimeInterval(-TrialAdmissionPolicy.assignmentWindow)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatId: 777,
        label: "paused trial",
        prompt: "Summarize the archive",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: admittedAt
      ),
      now: admittedAt
    )
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    let state = try learning.armJob(jobId: job.id, now: admittedAt)
    let identity = try installTrial(
      queue: queue,
      state: state,
      admittedAt: admittedAt
    )
    try queue.write { db in
      try db.execute(
        sql: "UPDATE scheduled_jobs SET status = ? WHERE id = ?",
        arguments: [ScheduledJobStatus.paused.rawValue, job.id]
      )
    }
    return TrialSweepFixture(
      queue: queue,
      learning: learning,
      identity: identity,
      assignmentDeadline: deadline
    )
  }

  func trialState() throws -> LearningTrialState? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT state FROM learning_trials WHERE trial_id = ?",
        arguments: [identity.trialId]
      ).flatMap(LearningTrialState.init(rawValue:))
    }
  }
}

private extension TrialSweepFixture {
  static func installTrial(
    queue: DatabaseQueue,
    state: JobLearningState,
    admittedAt: Date
  ) throws -> LearningTrialIdentity {
    let replacement = try LessonSet.canonical(
      jobId: state.jobId,
      lessons: ["Check the archive before answering."]
    )
    let manifest = CandidateSourceManifest(
      origin: .reflection,
      algorithm: .v1,
      jobId: state.jobId,
      epoch: state.epoch,
      triggerDigest: TriggerDigest(rawValue: SHA256Digest.hex("sweep-trigger")),
      triggerReason: .ownerCorrection,
      qualifyingIssueCodes: [],
      operationId: LearningOperationID(rawValue: "sweep-operation"),
      carrierDigest: CarrierDigest(rawValue: SHA256Digest.hex("sweep-carrier")),
      resultDigest: ReflectionResultDigest(rawValue: SHA256Digest.hex("sweep-result")),
      baseDigest: state.stableDigest,
      baseRevision: state.stableRevision,
      feedbackRevision: state.feedbackRevision,
      evidence: [],
      evaluations: [],
      feedback: [],
      predecessorCandidate: nil,
      predecessorFeedback: nil
    )
    let artifact = try CandidateArtifact(replacement: replacement, manifest: manifest)
    return try queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(
        db,
        artifact: artifact,
        now: admittedAt
      )
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, ?, 1, ?, ?, ?, 3, 0, ?, ?, ?)
          """,
        arguments: [
          state.jobId,
          state.epoch.value,
          state.stableDigest.rawValue,
          artifact.digest.rawValue,
          EpochSecondCodec.epoch(admittedAt),
          EpochSecondCodec.epoch(
            admittedAt.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow)
          ),
          EpochSecondCodec.epoch(
            admittedAt.addingTimeInterval(TrialAdmissionPolicy.decisionWindow)
          ),
          EpochSecondCodec.epoch(admittedAt),
          LearningTrialState.open.rawValue,
          LearningAlgorithm.v1.rawValue,
        ]
      )
      let identity = LearningTrialIdentity(
        trialId: db.lastInsertedRowID,
        jobId: state.jobId,
        epoch: state.epoch,
        generation: 1
      )
      try ScheduledLearningStoreGRDB.insertDecision(
        db,
        kind: AdmissionReceipt.kind,
        jobId: state.jobId,
        epoch: state.epoch,
        inputs: AdmissionDecisionInputs(candidateDigest: artifact.digest),
        result: AdmissionReceipt(
          candidateDigest: artifact.digest,
          replacementDigest: replacement.digest,
          trialId: identity.trialId,
          generation: identity.generation
        ),
        algorithm: .v1,
        now: admittedAt
      )
      return identity
    }
  }
}
