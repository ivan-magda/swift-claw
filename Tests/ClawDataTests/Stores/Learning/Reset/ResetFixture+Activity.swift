import ClawCore
import Foundation
import GRDB

@testable import ClawData

enum ResetCurrentEpochActivity: CaseIterable {
  case binding
  case compatibility
  case evidence
  case operation
  case evaluation
  case target
  case challenge
  case feedbackEvent
  case candidate
  case trial
  case assignment
}

enum ResetDirtyEffect: CaseIterable {
  case liveTrial
  case target
  case challenge
  case pendingOperation
  case unlistedStartedOperation
}

extension ResetFixture {
  func seedCurrentEpochActivity(_ activity: ResetCurrentEpochActivity) throws {
    let epoch = try state().epoch
    switch activity {
    case .binding:
      _ = try env.pendingBoundRun()
    case .compatibility:
      try seedCompatibility(epoch: epoch)
    case .evidence:
      try seedEvidence(epoch: epoch)
    case .operation:
      try env.queue.write { db in
        try insertOperation(
          db,
          id: "current-terminal-operation",
          jobId: env.jobId,
          epoch: epoch,
          state: .failed
        )
      }
    case .evaluation:
      try seedEvaluation(epoch: epoch)
    case .target:
      try seedTarget(epoch: epoch)
    case .challenge:
      try seedChallenge(epoch: epoch)
    case .feedbackEvent:
      try seedFeedbackEvent(epoch: epoch)
    case .candidate:
      _ = try seedCandidate(epoch: epoch)
    case .trial:
      try seedTrialActivity(epoch: epoch)
    case .assignment:
      try seedAssignmentActivity(epoch: epoch)
    }
  }

  func seedDirtyOldEpochEffect(_ effect: ResetDirtyEffect) throws {
    let oldEpoch = LearningEpoch(1)
    switch effect {
    case .liveTrial:
      let candidate = try seedCandidate(epoch: oldEpoch)
      try seedLiveTrial(candidate: candidate, epoch: oldEpoch)
    case .target:
      try seedTarget(epoch: oldEpoch, consumed: false)
    case .challenge:
      try seedChallenge(epoch: oldEpoch, consumed: false)
    case .pendingOperation:
      try env.queue.write { db in
        try insertOperation(
          db,
          id: "late-old-pending",
          jobId: env.jobId,
          epoch: oldEpoch,
          state: .pending
        )
      }
    case .unlistedStartedOperation:
      try env.queue.write { db in
        try insertStartedOperation(
          db,
          id: "late-old-started",
          jobId: env.jobId,
          epoch: oldEpoch
        )
      }
    }
  }
}

// MARK: - Current-Epoch Activity Fixtures

private extension ResetFixture {
  func insertOperation(
    _ db: Database,
    id: String,
    jobId: Int64,
    epoch: LearningEpoch,
    state: LearningOperationState
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO learning_operations(operation_id, job_id, learning_epoch, phase,
          source_digest, attempt_generation, state, created_at, key_digest)
        VALUES (?, ?, ?, 'evaluator', ?, 1, ?, ?, ?)
        """,
      arguments: [
        id,
        jobId,
        epoch.value,
        "source-\(id)",
        state.rawValue,
        EpochSecondCodec.epoch(env.now),
        "key-\(id)",
      ]
    )
  }

  func seedCompatibility(epoch: LearningEpoch) throws {
    let runId = try env.unboundRun()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO run_compatibility(run_id, job_id, learning_epoch)
          VALUES (?, ?, ?)
          """,
        arguments: [runId, env.jobId, epoch.value]
      )
    }
  }

  func seedEvidence(epoch: LearningEpoch) throws {
    let runId = try env.unboundRun()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_evidence(run_id, job_id, learning_epoch, evidence_digest,
            eligibility, classifier_version, sealed_at)
          VALUES (?, ?, ?, 'current-evidence', 'insufficient_evidence', '1', ?)
          """,
        arguments: [runId, env.jobId, epoch.value, EpochSecondCodec.epoch(env.now)]
      )
    }
  }

  func seedEvaluation(epoch: LearningEpoch) throws {
    let runId = try env.unboundRun()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_evaluations(evaluation_digest, job_id, learning_epoch, run_id,
            evidence_digest, outcome, issue_codes, rubric_version, evaluator_prompt_version,
            evaluator_schema_version, compatibility_digest, created_at)
          VALUES ('current-evaluation', ?, ?, ?, 'evidence', 'no_issue', '[]', '1', '1', '1',
            'compatibility', ?)
          """,
        arguments: [env.jobId, epoch.value, runId, EpochSecondCodec.epoch(env.now)]
      )
    }
  }

  func seedTarget(epoch: LearningEpoch, consumed: Bool = true) throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO feedback_targets(nonce, job_id, learning_epoch, subject_kind,
            subject_digest, allowed_actions, owner_user_id, chat_id, expires_at, consumed_at)
          VALUES (?, ?, ?, 'run', 'subject', '["result_useful"]', 1, 1, 1, ?)
          """,
        arguments: [
          consumed ? "current-consumed-target" : "late-old-live-target",
          env.jobId,
          epoch.value,
          consumed ? 1 : nil,
        ]
      )
    }
  }

  func seedChallenge(epoch: LearningEpoch, consumed: Bool = true) throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO feedback_challenges(owner_user_id, chat_id, job_id, learning_epoch,
            subject_kind, subject_digest, consumed_at, expires_at)
          VALUES (?, ?, ?, ?, 'run', 'subject', ?, 1)
          """,
        arguments: [
          consumed ? 1 : 2,
          consumed ? 1 : 2,
          env.jobId,
          epoch.value,
          consumed ? 1 : nil,
        ]
      )
    }
  }

  func seedFeedbackEvent(epoch: LearningEpoch) throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO feedback_events(job_id, learning_epoch, subject_kind, subject_digest,
            signal, actor, feedback_revision, occurred_at)
          VALUES (?, ?, 'run', 'subject', 'result_useful', 'owner', 1, 1)
          """,
        arguments: [env.jobId, epoch.value]
      )
    }
  }

  func seedCandidate(epoch: LearningEpoch) throws -> String {
    let digest = String(repeating: "c", count: 64)
    let replacement = try LessonSet.canonical(jobId: env.jobId, lessons: ["current candidate"])
    let state = try state()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO lesson_sets(job_id, digest, schema_version, canonical_bytes,
            source, created_at) VALUES (?, ?, ?, ?, ?, ?)
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
          VALUES (?, ?, ?, ?, ?, ?, ?, 'reflection', '{}', ?, ?)
          """,
        arguments: [
          digest,
          env.jobId,
          epoch.value,
          replacement.digest.rawValue,
          state.stableDigest.rawValue,
          state.stableRevision.value,
          state.feedbackRevision.value,
          LearningAlgorithm.v1.rawValue,
          EpochSecondCodec.epoch(env.now),
        ]
      )
    }
    return digest
  }

  func seedTrialActivity(epoch: LearningEpoch) throws {
    let candidate = try seedCandidate(epoch: LearningEpoch(epoch.value - 1))
    _ = try seedClosedTrial(candidate: candidate, epoch: epoch)
  }

  func seedAssignmentActivity(epoch: LearningEpoch) throws {
    let candidate = try seedCandidate(epoch: LearningEpoch(epoch.value - 1))
    let trialId = try seedClosedTrial(
      candidate: candidate,
      epoch: LearningEpoch(epoch.value - 1)
    )
    let runId = try env.unboundRun()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO trial_assignments(run_id, trial_id, job_id, learning_epoch,
            trial_generation, assigned_at, state, evaluation_required)
          VALUES (?, ?, ?, ?, 1, ?, 'created', 1)
          """,
        arguments: [
          runId,
          trialId,
          env.jobId,
          epoch.value,
          EpochSecondCodec.epoch(env.now),
        ]
      )
    }
  }

  func seedClosedTrial(candidate: String, epoch: LearningEpoch) throws -> Int64 {
    let state = try state()
    return try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, close_reason, algorithm)
          VALUES (?, ?, ?, ?, 1, ?, ?, ?, 3, 0, ?, 'closed', 'fixture', ?)
          """,
        arguments: [
          env.jobId,
          epoch.value,
          state.stableDigest.rawValue,
          candidate,
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          LearningAlgorithm.v1.rawValue,
        ]
      )
      return db.lastInsertedRowID
    }
  }

  func seedLiveTrial(candidate: String, epoch: LearningEpoch) throws {
    let state = try state()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, ?, 1, ?, ?, ?, 3, 0, ?, 'open', ?)
          """,
        arguments: [
          env.jobId,
          epoch.value,
          state.stableDigest.rawValue,
          candidate,
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          LearningAlgorithm.v1.rawValue,
        ]
      )
    }
  }

  func insertStartedOperation(
    _ db: Database,
    id: String,
    jobId: Int64,
    epoch: LearningEpoch
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO learning_operations(operation_id, job_id, learning_epoch, phase,
          source_digest, carrier_digest, route, provider_call_id, attempt_generation, state,
          reserved_tokens, reserved_cost_usd, reservation_state, created_at, key_digest)
        VALUES (?, ?, ?, 'evaluator', ?, 'carrier', 'route', 'call', 1, 'started',
          1, 0.1, 'open', ?, ?)
        """,
      arguments: [
        id,
        jobId,
        epoch.value,
        "source-\(id)",
        EpochSecondCodec.epoch(env.now),
        "key-\(id)",
      ]
    )
  }
}
