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

  @Test func aTrialPastItsAssignmentDeadlineDrainsWithoutConsuming() throws {
    // given
    let env = try FireBindingEnvironment.make(withOpenTrial: true, consumedAssignments: 0)
    let afterDeadline = env.assignmentDeadline.addingTimeInterval(1)

    // when
    let fired = try #require(
      try env.jobs.claimAndFire(
        jobId: env.jobId,
        due: env.due,
        fireAt: env.due,
        nextOccurrence: nil,
        now: afterDeadline
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
    let candidateDigest = SHA256Digest.hex("candidate-\(jobId)")
    let baseDigest = LessonSet.empty(jobId: jobId).digest.rawValue
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
            created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          jobId, candidate.digest.rawValue, candidate.schemaVersion, candidate.canonicalBytes,
          LessonSetSource.reflectorCandidate.rawValue, EpochSecondCodec.epoch(admittedAt),
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO learning_candidates(candidate_digest, job_id, learning_epoch,
            replacement_digest, base_digest, base_revision, frozen_feedback_revision, origin,
            source_manifest, algorithm, created_at)
          VALUES (?, ?, 1, ?, ?, 0, 0, ?, '{}', ?, ?)
          """,
        arguments: [
          candidateDigest, jobId, candidate.digest.rawValue, baseDigest,
          LearningPhase.reflector.rawValue, LearningAlgorithm.v1.rawValue,
          EpochSecondCodec.epoch(admittedAt),
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, 1, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          jobId, baseDigest, candidateDigest,
          EpochSecondCodec.epoch(admittedAt),
          EpochSecondCodec.epoch(admittedAt.addingTimeInterval(assignmentWindow)),
          EpochSecondCodec.epoch(admittedAt.addingTimeInterval(decisionWindow)),
          assignmentLimit, consumedAssignments, EpochSecondCodec.epoch(admittedAt),
          LearningTrialState.open.rawValue, LearningAlgorithm.v1.rawValue,
        ]
      )
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = ? WHERE job_id = ?",
        arguments: [db.lastInsertedRowID, jobId]
      )
    }
  }
}
