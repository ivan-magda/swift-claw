import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

/// The fire transaction is the one place exposure is granted, so it is the one place a trial
/// assignment may be consumed: a created run consumes one even when it later fails, and every
/// path that creates no run consumes none.
@Suite struct FireBindingTests {
  @Test func overlapSkipAndCasMissConsumeNoAssignment() throws {
    // given — a job with an open trial holding one candidate assignment already consumed
    let env = try FireBindingEnvironment.make(withOpenTrial: true, consumedAssignments: 1)
    try env.startLiveRun()

    // when — a stale occurrence loses the compare-and-swap, and the live run skips the next fire
    let staleClaim = try env.jobs.claimAndFire(
      jobId: env.jobId,
      due: env.due.addingTimeInterval(-3_600),
      fireAt: env.due,
      nextOccurrence: nil,
      now: env.due
    )
    let skipped = try env.jobs.claimAndFire(
      jobId: env.jobId,
      due: env.due,
      fireAt: env.due,
      nextOccurrence: env.due.addingTimeInterval(3_600),
      now: env.due
    )

    // then
    #expect(staleClaim == nil)
    #expect(skipped == nil)
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    #expect(trial.consumedAssignments == 1)
  }

  @Test func aMisfireSkipConsumesNoAssignment() throws {
    // given
    let env = try FireBindingEnvironment.make(withOpenTrial: true, consumedAssignments: 0)

    // when — the occurrence is dropped without a run
    let skipped = try env.jobs.skipMisfire(
      jobId: env.jobId,
      due: env.due,
      nextOccurrence: env.due.addingTimeInterval(3_600),
      skippedCount: 1,
      now: env.due
    )

    // then
    #expect(skipped)
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    #expect(trial.consumedAssignments == 0)
  }

  @Test func firstFireArmsStateAndEmptySetAtomically() throws {
    // given — a job that has never fired under learning
    let env = try FireBindingEnvironment.make(withOpenTrial: false, consumedAssignments: 0)

    // when
    let fired = try #require(
      try env.jobs.claimAndFire(
        jobId: env.jobId,
        due: env.due,
        fireAt: env.due,
        nextOccurrence: nil,
        now: env.due
      )
    )

    // then
    let binding = try #require(fired.binding)
    #expect(binding.effectiveDigest == LessonSet.empty(jobId: env.jobId).digest)
    #expect(binding.trialId == nil)
    #expect(try env.learning.lessonSet(jobId: env.jobId, digest: binding.effectiveDigest) != nil)
    #expect(try env.learning.binding(runId: fired.runId) == binding)
  }

  @Test func aTrialFireConsumesExactlyOneAssignment() throws {
    // given
    let env = try FireBindingEnvironment.make(withOpenTrial: true, consumedAssignments: 0)

    // when
    let fired = try #require(
      try env.jobs.claimAndFire(
        jobId: env.jobId,
        due: env.due,
        fireAt: env.due,
        nextOccurrence: nil,
        now: env.due
      )
    )

    // then
    let binding = try #require(fired.binding)
    #expect(binding.trialId != nil)
    #expect(binding.fireKind == .scheduledOccurrence)
    #expect(binding.effectiveDigest == env.candidateDigest)
    #expect(binding.effectiveDigest != binding.stableDigest)
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    #expect(trial.consumedAssignments == 1)
  }

  @Test func aRunNowFireConsumesAnAssignmentAndFreezesItsOwnKind() throws {
    // given
    let env = try FireBindingEnvironment.make(withOpenTrial: true, consumedAssignments: 0)

    // when — the owner asks for the same job by hand
    let outcome = try env.jobs.fireNow(jobId: env.jobId, now: env.due)

    // then
    guard case .fired(let fired) = outcome else {
      Issue.record("expected a fired run, got \(outcome)")
      return
    }
    let binding = try #require(fired.binding)
    #expect(binding.fireKind == .ownerRunNow)
    #expect(binding.trialId != nil)
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    #expect(trial.consumedAssignments == 1)
  }

  @Test func aTrialAtItsAssignmentDeadlineDrainsWithoutConsuming() throws {
    // given
    let env = try FireBindingEnvironment.make(withOpenTrial: true, consumedAssignments: 0)

    // when
    let fired = try #require(
      try env.jobs.claimAndFire(
        jobId: env.jobId,
        due: env.due,
        fireAt: env.due,
        nextOccurrence: nil,
        now: env.assignmentDeadline
      )
    )

    // then
    let binding = try #require(fired.binding)
    // The occurrence, not the late tick that noticed it: `now` is 30 days past `fireAt` here.
    #expect(binding.occurrenceAt == env.due)
    #expect(binding.trialId == nil)
    #expect(binding.effectiveDigest == binding.stableDigest)
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    #expect(trial.state == .draining)
    #expect(trial.consumedAssignments == 0)
  }

  @Test func aTrialAtItsAssignmentLimitDrainsWithoutConsuming() throws {
    // given — every assignment the trial may ever grant is already out
    let env = try FireBindingEnvironment.make(
      withOpenTrial: true,
      consumedAssignments: FireBindingEnvironment.assignmentLimit
    )

    // when
    let fired = try #require(
      try env.jobs.claimAndFire(
        jobId: env.jobId,
        due: env.due,
        fireAt: env.due,
        nextOccurrence: nil,
        now: env.due
      )
    )

    // then
    let binding = try #require(fired.binding)
    #expect(binding.trialId == nil)
    #expect(binding.effectiveDigest == binding.stableDigest)
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    #expect(trial.state == .draining)
    #expect(trial.consumedAssignments == FireBindingEnvironment.assignmentLimit)
  }

  @Test func thirdFireAtomicallyConsumesAndDrains() throws {
    // given
    let env = try FireBindingEnvironment.make(withOpenTrial: true, consumedAssignments: 0)

    // when
    var bindings: [RunLearningBinding] = []
    for offset in 0..<FireBindingEnvironment.assignmentLimit {
      let fire = try #require(
        try env.firedNow(at: env.due.addingTimeInterval(Double(offset)))
      )
      bindings.append(try #require(fire.binding))
      try env.finishRun(fire.runId)
    }

    // then
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    #expect(bindings.allSatisfy { $0.trialId == trial.trialId })
    #expect(trial.consumedAssignments == FireBindingEnvironment.assignmentLimit)
    #expect(trial.state == .draining)
    #expect(try env.assignmentCount() == FireBindingEnvironment.assignmentLimit)

    let fourth = try #require(try env.firedNow(at: env.due.addingTimeInterval(4)))
    #expect(fourth.binding?.trialId == nil)
    #expect(fourth.binding?.effectiveDigest == fourth.binding?.stableDigest)
  }

  @Test func preAdmissionOccurrenceUsesStableAndConsumesNoExposure() throws {
    // given
    let env = try FireBindingEnvironment.make(withOpenTrial: true, consumedAssignments: 0)
    try env.moveAdmission(to: env.due.addingTimeInterval(60))

    // when
    let fired = try #require(
      try env.jobs.claimAndFire(
        jobId: env.jobId,
        due: env.due,
        fireAt: env.due,
        nextOccurrence: nil,
        now: env.due.addingTimeInterval(120)
      )
    )

    // then
    #expect(fired.binding?.trialId == nil)
    #expect(fired.binding?.effectiveDigest == fired.binding?.stableDigest)
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    #expect(trial.state == .open)
    #expect(trial.consumedAssignments == 0)
  }

  @Test func assignmentInsertFailureRollsBackRunBindingCounterAndDrain() throws {
    // given
    let env = try FireBindingEnvironment.make(withOpenTrial: true, consumedAssignments: 2)
    try env.rejectAssignmentInserts()

    // when / then
    #expect {
      _ = try env.jobs.fireNow(jobId: env.jobId, now: env.due)
    } throws: { _ in true }
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    #expect(trial.state == .open)
    #expect(trial.consumedAssignments == 2)
    #expect(try env.assignmentCount() == 0)
    #expect(try env.bindingCount() == 0)
    #expect(try env.runCount() == 0)
  }

  @Test(arguments: FireSourceCorruption.allCases)
  func fireSelectionRequiresEveryCurrentTrialSource(
    _ corruption: FireSourceCorruption
  ) throws {
    // given
    let env = try FireBindingEnvironment.make(withOpenTrial: true, consumedAssignments: 0)
    try env.apply(corruption)

    // when / then
    #expect {
      _ = try env.jobs.fireNow(jobId: env.jobId, now: env.due)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
    #expect(try env.runCount() == 0)
    #expect(try env.bindingCount() == 0)
  }

  @Test func pausingAndResumingNeitherExtendsTheDeadlineNorRevokesAnAssignment() throws {
    // given — a trial run already bound to this job's assignment
    let env = try FireBindingEnvironment.make(withOpenTrial: true, consumedAssignments: 0)
    let fired = try #require(
      try env.jobs.claimAndFire(
        jobId: env.jobId,
        due: env.due,
        fireAt: env.due,
        nextOccurrence: env.due.addingTimeInterval(3_600),
        now: env.due
      )
    )

    // when — the owner mutes the schedule and unmutes it a day later
    let laterDay = env.due.addingTimeInterval(86_400)
    _ = try env.jobs.pause(id: env.jobId, now: laterDay)
    _ = try env.jobs.resume(
      id: env.jobId,
      nextOccurrence: laterDay.addingTimeInterval(3_600),
      now: laterDay
    )

    // then
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    #expect(trial.assignmentDeadline == env.assignmentDeadline)
    #expect(trial.consumedAssignments == 1)
    #expect(try env.learning.binding(runId: fired.runId)?.trialId == trial.trialId)
  }

  @Test func aDisarmedDaemonWritesNoLearningRowAtAll() throws {
    // given — CLAW_LEARNING_ENABLED unset
    let env = try FireBindingEnvironment.make(
      withOpenTrial: false,
      consumedAssignments: 0,
      learningEnabled: false
    )

    // when
    let fired = try #require(
      try env.jobs.claimAndFire(
        jobId: env.jobId,
        due: env.due,
        fireAt: env.due,
        nextOccurrence: nil,
        now: env.due
      )
    )

    // then
    #expect(fired.binding == nil)
    #expect(try env.learning.binding(runId: fired.runId) == nil)
    #expect(try env.rowCount(in: "job_learning_state") == 0)
    #expect(try env.rowCount(in: "lesson_sets") == 0)
    #expect(try env.rowCount(in: "run_learning_bindings") == 0)
  }
}

enum FireSourceCorruption: CaseIterable {
  case currentEpoch
  case currentBase
  case currentRevision
  case trialBase
  case trialGeneration
  case trialAlgorithm
  case assignmentDeadline
  case decisionDeadline
  case maximumAssignments
  case consumedAssignments
  case candidateEpoch
  case candidateBase
  case candidateBaseRevision
  case candidateReplacement
  case candidateAlgorithm
  case admissionReceipt
}

// MARK: - Environment

/// A migrated database holding one scheduled job, optionally armed with an open trial over a
/// two-lesson candidate set, plus the two stores the fire path fuses together.
private struct FireBindingEnvironment {
  static let assignmentLimit = 3
  static let assignmentWindow: TimeInterval = 30 * 24 * 60 * 60
  static let decisionWindow: TimeInterval = 37 * 24 * 60 * 60

  let queue: DatabaseQueue
  let jobs: ScheduledJobStoreGRDB
  let learning: ScheduledLearningStoreGRDB
  let jobId: Int64
  let due: Date
  let assignmentDeadline: Date
  let candidateDigest: LessonSetDigest

  static func make(
    withOpenTrial: Bool,
    consumedAssignments: Int,
    learningEnabled: Bool = true
  ) throws -> FireBindingEnvironment {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: learningEnabled)
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    let due = Date(timeIntervalSince1970: 1_782_000_600)
    let admittedAt = due.addingTimeInterval(-86_400)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatId: 777,
        label: "digest",
        prompt: "Summarize my unread items",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: due
      ),
      now: admittedAt
    )

    let candidate = try LessonSet.canonical(
      jobId: job.id,
      lessons: ["Check the archive before answering"]
    )
    if withOpenTrial {
      _ = try learning.armJob(jobId: job.id, now: admittedAt)
      try openTrial(
        queue,
        jobId: job.id,
        candidate: candidate,
        admittedAt: admittedAt,
        consumedAssignments: consumedAssignments
      )
    }

    return FireBindingEnvironment(
      queue: queue,
      jobs: jobs,
      learning: learning,
      jobId: job.id,
      due: due,
      assignmentDeadline: admittedAt.addingTimeInterval(assignmentWindow),
      candidateDigest: candidate.digest
    )
  }

  /// A live run on the job's own session, planted without firing so the overlap guard trips on a
  /// fire that has consumed nothing.
  func startLiveRun() throws {
    try queue.write { db in
      let sessionId = try SessionMessageStoreGRDB.upsertSession(
        db,
        sessionKey: SessionKey.scheduledJob(id: jobId),
        now: due
      )
      try db.execute(
        sql: "UPDATE scheduled_jobs SET session_id = ? WHERE id = ?",
        arguments: [sessionId, jobId]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId, MessageRole.user.rawValue, "Summarize my unread items",
          Provenance.trusted.rawValue, due,
        ]
      )
      let triggerMessageId = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_message_id,
            origin, job_id)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId, RunState.pending.rawValue, due, due, triggerMessageId,
          RunOrigin.scheduled.rawValue, jobId,
        ]
      )
    }
  }

  func rowCount(in table: String) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
    }
  }

  func firedNow(at now: Date) throws -> ClaimedFire? {
    guard case .fired(let fire) = try jobs.fireNow(jobId: jobId, now: now) else {
      return nil
    }
    return fire
  }

  func finishRun(_ runId: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE runs SET state = ? WHERE id = ?",
        arguments: [RunState.done.rawValue, runId]
      )
    }
  }

  func assignmentCount() throws -> Int { try rowCount(in: "trial_assignments") }
  func bindingCount() throws -> Int { try rowCount(in: "run_learning_bindings") }
  func runCount() throws -> Int { try rowCount(in: "runs") }

  func moveAdmission(to admittedAt: Date) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          UPDATE learning_trials
          SET admitted_at = ?, cohort_cutoff = ?, assignment_deadline = ?, decision_deadline = ?
          WHERE job_id = ?
          """,
        arguments: [
          EpochSecondCodec.epoch(admittedAt),
          EpochSecondCodec.epoch(admittedAt),
          EpochSecondCodec.epoch(admittedAt.addingTimeInterval(Self.assignmentWindow)),
          EpochSecondCodec.epoch(admittedAt.addingTimeInterval(Self.decisionWindow)),
          jobId,
        ]
      )
    }
  }

  func rejectAssignmentInserts() throws {
    try queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER reject_trial_assignment BEFORE INSERT ON trial_assignments
          BEGIN SELECT RAISE(ABORT, 'injected assignment failure'); END
          """
      )
    }
  }

  func apply(_ corruption: FireSourceCorruption) throws {
    try queue.write { db in
      let base = LessonSet.empty(jobId: jobId).digest.rawValue
      switch corruption {
      case .currentEpoch:
        try db.execute(
          sql: "UPDATE job_learning_state SET learning_epoch = 2 WHERE job_id = ?",
          arguments: [jobId]
        )
      case .currentBase:
        try db.execute(
          sql: "UPDATE job_learning_state SET stable_lesson_set_digest = ? WHERE job_id = ?",
          arguments: [candidateDigest.rawValue, jobId]
        )
      case .currentRevision:
        try db.execute(
          sql: "UPDATE job_learning_state SET stable_revision = 1 WHERE job_id = ?",
          arguments: [jobId]
        )
      case .trialBase:
        try db.execute(
          sql: "UPDATE learning_trials SET base_digest = ? WHERE job_id = ?",
          arguments: [candidateDigest.rawValue, jobId]
        )
      case .trialGeneration:
        try db.execute(
          sql: "UPDATE learning_trials SET generation = 2 WHERE job_id = ?",
          arguments: [jobId]
        )
      case .trialAlgorithm:
        try db.execute(
          sql: "UPDATE learning_trials SET algorithm = 'unknown' WHERE job_id = ?",
          arguments: [jobId]
        )
      case .assignmentDeadline:
        try db.execute(
          sql:
            "UPDATE learning_trials SET assignment_deadline = assignment_deadline + 1 WHERE job_id = ?",
          arguments: [jobId]
        )
      case .decisionDeadline:
        try db.execute(
          sql:
            "UPDATE learning_trials SET decision_deadline = decision_deadline + 1 WHERE job_id = ?",
          arguments: [jobId]
        )
      case .maximumAssignments:
        try db.execute(
          sql: "UPDATE learning_trials SET max_assignments = 4 WHERE job_id = ?",
          arguments: [jobId]
        )
      case .consumedAssignments:
        try db.execute(
          sql: "UPDATE learning_trials SET consumed_assignments = 4 WHERE job_id = ?",
          arguments: [jobId]
        )
      case .candidateEpoch:
        try db.execute(sql: "UPDATE learning_candidates SET learning_epoch = 2")
      case .candidateBase:
        try db.execute(
          sql: "UPDATE learning_candidates SET base_digest = replacement_digest"
        )
      case .candidateBaseRevision:
        try db.execute(sql: "UPDATE learning_candidates SET base_revision = 99")
      case .candidateReplacement:
        try db.execute(
          sql: "UPDATE learning_candidates SET replacement_digest = ?",
          arguments: [base]
        )
      case .candidateAlgorithm:
        try db.execute(sql: "UPDATE learning_candidates SET algorithm = 'unknown'")
      case .admissionReceipt:
        guard
          let raw = try String.fetchOne(
            db,
            sql: "SELECT result FROM learning_decisions WHERE kind = ?",
            arguments: [AdmissionReceipt.kind]
          ),
          let bytes = raw.data(using: .utf8),
          let receipt = try? JSONDecoder().decode(AdmissionReceipt.self, from: bytes)
        else {
          throw StoreError.unexpected("fixture admission receipt is missing")
        }
        let changed = AdmissionReceipt(
          candidateDigest: receipt.candidateDigest,
          replacementDigest: receipt.replacementDigest,
          trialId: receipt.trialId,
          generation: receipt.generation + 1
        )
        let changedBytes = try CanonicalJSON.data(encoding: changed)
        guard let changedRaw = String(bytes: changedBytes, encoding: .utf8) else {
          throw StoreError.unexpected("fixture admission receipt is not UTF-8")
        }
        try db.execute(
          sql: "UPDATE learning_decisions SET result = ? WHERE kind = ?",
          arguments: [changedRaw, AdmissionReceipt.kind]
        )
      }
    }
  }
}

// MARK: - Trial Fixture

private extension FireBindingEnvironment {
  /// The rows an admitted candidate leaves behind: its replacement lesson set, the frozen
  /// candidate record and the open trial that exposes it.
  static func openTrial(
    _ queue: DatabaseQueue,
    jobId: Int64,
    candidate: LessonSet,
    admittedAt: Date,
    consumedAssignments: Int
  ) throws {
    let baseDigest = LessonSet.empty(jobId: jobId).digest
    let manifest = CandidateSourceManifest(
      origin: .reflection,
      algorithm: .v1,
      jobId: jobId,
      epoch: LearningEpoch(1),
      triggerDigest: TriggerDigest(rawValue: SHA256Digest.hex("trigger-\(jobId)")),
      triggerReason: .ownerCorrection,
      qualifyingIssueCodes: [],
      operationId: LearningOperationID(rawValue: "fixture-operation"),
      carrierDigest: CarrierDigest(rawValue: SHA256Digest.hex("carrier-\(jobId)")),
      resultDigest: ReflectionResultDigest(rawValue: SHA256Digest.hex("result-\(jobId)")),
      baseDigest: baseDigest,
      baseRevision: StableRevision(0),
      feedbackRevision: FeedbackRevision(0),
      evidence: [],
      evaluations: [],
      feedback: [],
      predecessorCandidate: nil,
      predecessorFeedback: nil
    )
    let artifact = try CandidateArtifact(replacement: candidate, manifest: manifest)
    try queue.write { db in
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
          VALUES (?, 1, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          jobId, baseDigest.rawValue, artifact.digest.rawValue,
          EpochSecondCodec.epoch(admittedAt),
          EpochSecondCodec.epoch(admittedAt.addingTimeInterval(assignmentWindow)),
          EpochSecondCodec.epoch(admittedAt.addingTimeInterval(decisionWindow)),
          assignmentLimit, consumedAssignments, EpochSecondCodec.epoch(admittedAt),
          LearningTrialState.open.rawValue, LearningAlgorithm.v1.rawValue,
        ]
      )
      let trialId = db.lastInsertedRowID
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = ? WHERE job_id = ?",
        arguments: [trialId, jobId]
      )
      try ScheduledLearningStoreGRDB.insertDecision(
        db,
        kind: AdmissionReceipt.kind,
        jobId: jobId,
        epoch: LearningEpoch(1),
        inputs: AdmissionDecisionInputs(candidateDigest: artifact.digest),
        result: AdmissionReceipt(
          candidateDigest: artifact.digest,
          replacementDigest: candidate.digest,
          trialId: trialId,
          generation: 1
        ),
        algorithm: .v1,
        now: admittedAt
      )
    }
  }
}
