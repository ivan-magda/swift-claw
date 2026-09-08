import ClawCore
import Foundation
import GRDB

@testable import ClawData

struct ResetFixture {
  let env: BoundRunEnvironment

  static func make() throws -> ResetFixture {
    ResetFixture(env: try BoundRunEnvironment.make())
  }

  func installStableLessons(_ lessons: [String]) throws -> LessonSet {
    _ = try env.learning.armJob(jobId: env.jobId, now: env.now)
    let set = try LessonSet.canonical(jobId: env.jobId, lessons: lessons)
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
            created_at) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          set.jobId,
          set.digest.rawValue,
          set.schemaVersion,
          set.canonicalBytes,
          LessonSetSource.reflectorCandidate.rawValue,
          EpochSecondCodec.epoch(env.now),
        ]
      )
      try db.execute(
        sql: """
          UPDATE job_learning_state SET stable_lesson_set_digest = ?, stable_revision = 4
          WHERE job_id = ?
          """,
        arguments: [set.digest.rawValue, env.jobId]
      )
    }
    return set
  }

  func setFeedbackRevision(_ revision: Int64) throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET feedback_revision = ? WHERE job_id = ?",
        arguments: [revision, env.jobId]
      )
    }
  }

  func seedOpenAndDrainingTrials(base: LessonSetDigest) throws -> [Int64] {
    try env.queue.write { db in
      try db.execute(sql: "DROP INDEX idx_learning_trials_live_job")
      var ids: [Int64] = []
      for (index, state) in [LearningTrialState.open, .draining].enumerated() {
        let candidateDigest = String(repeating: index == 0 ? "a" : "b", count: 64)
        let replacement = try LessonSet.canonical(
          jobId: env.jobId,
          lessons: ["replacement-\(index)"]
        )
        try db.execute(
          sql: """
            INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
              created_at) VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            env.jobId,
            replacement.digest.rawValue,
            replacement.schemaVersion,
            replacement.canonicalBytes,
            LessonSetSource.reflectorCandidate.rawValue,
            EpochSecondCodec.epoch(env.now),
          ]
        )
        try db.execute(
          sql: """
            INSERT INTO learning_candidates(candidate_digest, job_id, learning_epoch,
              replacement_digest, base_digest, base_revision, frozen_feedback_revision, origin,
              source_manifest, algorithm, created_at)
            VALUES (?, ?, 1, ?, ?, 4, 7, 'reflection', '{}', ?, ?)
            """,
          arguments: [
            candidateDigest,
            env.jobId,
            replacement.digest.rawValue,
            base.rawValue,
            LearningAlgorithm.v1.rawValue,
            EpochSecondCodec.epoch(env.now),
          ]
        )
        try db.execute(
          sql: """
            INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
              generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
              consumed_assignments, cohort_cutoff, state, algorithm)
            VALUES (?, 1, ?, ?, ?, ?, ?, ?, 3, 0, ?, ?, ?)
            """,
          arguments: [
            env.jobId,
            base.rawValue,
            candidateDigest,
            index + 1,
            EpochSecondCodec.epoch(env.now),
            EpochSecondCodec.epoch(env.now.addingTimeInterval(60)),
            EpochSecondCodec.epoch(env.now.addingTimeInterval(120)),
            EpochSecondCodec.epoch(env.now),
            state.rawValue,
            LearningAlgorithm.v1.rawValue,
          ]
        )
        ids.append(db.lastInsertedRowID)
      }
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = ? WHERE job_id = ?",
        arguments: [ids[0], env.jobId]
      )
      return ids
    }
  }

  func createOtherJob() throws -> Int64 {
    let job = try env.jobs.create(
      NewScheduledJob(
        ownerChatId: 888,
        label: "other",
        prompt: "Other job",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: env.now
      ),
      now: env.now
    )
    return job.id
  }

  func seedFeedbackControls(otherJobId: Int64) throws {
    try env.queue.write { db in
      for (nonce, jobId, epoch) in [
        ("target-secret-nonce-current", env.jobId, 1),
        ("target-secret-nonce-old", env.jobId, 0),
        ("target-secret-nonce-other", otherJobId, 1),
      ] {
        try db.execute(
          sql: """
            INSERT INTO feedback_targets(nonce, job_id, learning_epoch, subject_kind,
              subject_digest, allowed_actions, owner_user_id, chat_id, expires_at)
            VALUES (?, ?, ?, 'run', 'subject', '["result_useful"]', ?, ?, ?)
            """,
          arguments: [nonce, jobId, epoch, jobId + 100, jobId + 200, 1]
        )
      }
      for (owner, chat, jobId, epoch) in [
        (100, 200, env.jobId, 1),
        (101, 201, env.jobId, 0),
        (102, 202, otherJobId, 1),
      ] {
        try db.execute(
          sql: """
            INSERT INTO feedback_challenges(owner_user_id, chat_id, job_id, learning_epoch,
              subject_kind, subject_digest, expires_at)
            VALUES (?, ?, ?, ?, 'run', 'subject', 1)
            """,
          arguments: [owner, chat, jobId, epoch]
        )
      }
      try db.execute(
        sql: """
          INSERT INTO feedback_challenges(owner_user_id, chat_id, job_id, learning_epoch,
            subject_kind, subject_digest, expires_at)
          VALUES (103, 203, ?, 0, 'run', 'history', 1)
          """,
        arguments: [env.jobId]
      )
      let historyId = db.lastInsertedRowID
      try db.execute(
        sql: "UPDATE feedback_challenges SET superseded_by = ? WHERE challenge_id = ?",
        arguments: [historyId, historyId]
      )
    }
  }

  func seedOperations(otherJobId: Int64) throws {
    try env.queue.write { db in
      try insertOperation(db, id: "op-pending", jobId: env.jobId, state: .pending)
      try insertOperation(db, id: "op-claimed", jobId: env.jobId, state: .claimed)
      try insertOperation(db, id: "op-started", jobId: env.jobId, state: .started)
      try insertOperation(db, id: "op-other", jobId: otherJobId, state: .claimed)
    }
  }

  func insertOperation(
    _ db: Database,
    id: String,
    jobId: Int64,
    state: LearningOperationState
  ) throws {
    let started = state == .started
    try db.execute(
      sql: """
        INSERT INTO learning_operations(operation_id, job_id, learning_epoch, phase,
          source_digest, carrier_digest, route, provider_call_id, attempt_generation, state,
          reserved_tokens, reserved_cost_usd, reservation_state, created_at, key_digest)
        VALUES (?, ?, 1, 'evaluator', ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        id,
        jobId,
        "source-\(id)",
        started ? "carrier-\(id)" : nil,
        started ? "route" : nil,
        started ? "provider-secret-call" : nil,
        state.rawValue,
        started ? 300 : nil,
        started ? 0.5 : nil,
        started ? LearningReservationState.open.rawValue : nil,
        EpochSecondCodec.epoch(env.now),
        "key-\(id)",
      ]
    )
  }
}
