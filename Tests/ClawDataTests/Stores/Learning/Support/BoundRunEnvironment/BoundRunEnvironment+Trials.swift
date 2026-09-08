import ClawCore
import Foundation
import GRDB

@testable import ClawData

enum AssignmentIdentityCorruption: CaseIterable {
  case assignmentJob
  case assignmentEpoch
  case assignmentGeneration
  case bindingJob
  case bindingEpoch
  case bindingTrial
  case bindingGeneration
  case bindingStableDigest
  case bindingEffectiveDigest
}

enum LiveTrialStateDrift: CaseIterable {
  case stableDigest
  case stableRevision
}

enum TrialSnapshotCorruption: CaseIterable {
  case count
  case assignmentJob
}

extension BoundRunEnvironment {
  func installTrial() throws {
    _ = try installTrial(jobId: jobId)
  }

  @discardableResult
  func installTrial(jobId: Int64) throws -> LearningTrialIdentity {
    let state = try learning.armJob(jobId: jobId, now: now)
    let base = LessonSet.empty(jobId: jobId)
    let replacement = try LessonSet.canonical(
      jobId: jobId,
      lessons: ["Check the archive before answering"]
    )
    let manifest = CandidateSourceManifest(
      origin: .reflection,
      algorithm: .v1,
      jobId: jobId,
      epoch: state.epoch,
      triggerDigest: TriggerDigest(rawValue: SHA256Digest.hex("trial-trigger-\(jobId)")),
      triggerReason: .ownerCorrection,
      qualifyingIssueCodes: [],
      operationId: LearningOperationID(rawValue: "trial-fixture-operation"),
      carrierDigest: CarrierDigest(rawValue: SHA256Digest.hex("trial-carrier-\(jobId)")),
      resultDigest: ReflectionResultDigest(rawValue: SHA256Digest.hex("trial-result-\(jobId)")),
      baseDigest: base.digest,
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
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(db, artifact: artifact, now: now)
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, ?, 1, ?, ?, ?, 3, 0, ?, ?, ?)
          """,
        arguments: [
          jobId,
          state.epoch.value,
          base.digest.rawValue,
          artifact.digest.rawValue,
          EpochSecondCodec.epoch(now),
          EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow)),
          EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.decisionWindow)),
          EpochSecondCodec.epoch(now),
          LearningTrialState.open.rawValue,
          LearningAlgorithm.v1.rawValue,
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
        epoch: state.epoch,
        inputs: AdmissionDecisionInputs(candidateDigest: artifact.digest),
        result: AdmissionReceipt(
          candidateDigest: artifact.digest,
          replacementDigest: replacement.digest,
          trialId: trialId,
          generation: 1
        ),
        algorithm: .v1,
        now: now
      )
      return LearningTrialIdentity(
        trialId: trialId,
        jobId: jobId,
        epoch: state.epoch,
        generation: 1
      )
    }
  }

  func sealedTrialEvidence() throws -> SealedEvidence {
    try seal(runId: settledBoundRun())
  }

  func assignmentState(runId: Int64) throws -> TrialAssignmentState? {
    try queue.read { db in
      let raw = try String.fetchOne(
        db,
        sql: "SELECT state FROM trial_assignments WHERE run_id = ?",
        arguments: [runId]
      )
      return raw.flatMap(TrialAssignmentState.init(rawValue:))
    }
  }

  func assignment(runId: Int64) throws -> TrialAssignment? {
    switch try learning.recomputeAssignment(runId: runId, now: now) {
    case .notAssigned, .stale:
      return nil
    case .unchanged(let assignment), .updated(let assignment):
      return assignment
    }
  }

  func corruptAssignmentGeneration(runId: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql:
          "UPDATE trial_assignments SET trial_generation = trial_generation + 1 WHERE run_id = ?",
        arguments: [runId]
      )
    }
  }

  func resetAssignmentCache(
    runId: Int64,
    state: TrialAssignmentState
  ) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          UPDATE trial_assignments
          SET state = ?, outcome = NULL, issue_codes = NULL, evaluation_digest = NULL,
            evaluation_required = 1, effective_feedback_revision = NULL, resolved_at = NULL
          WHERE run_id = ?
          """,
        arguments: [state.rawValue, runId]
      )
    }
  }

  func setAssignmentFeedbackRevision(runId: Int64, revision: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          UPDATE trial_assignments SET effective_feedback_revision = ? WHERE run_id = ?
          """,
        arguments: [revision, runId]
      )
    }
  }

  func apply(
    _ corruption: AssignmentIdentityCorruption,
    runId: Int64
  ) throws {
    if case .bindingJob = corruption {
      let otherJob = try jobs.create(
        NewScheduledJob(
          ownerChatId: 777,
          label: "foreign binding",
          prompt: "Read a different archive",
          recurrence: nil,
          timezone: "Europe/Berlin",
          nextOccurrence: now
        ),
        now: now
      )
      try queue.write { db in
        try db.execute(
          sql: """
            INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
              created_at)
            SELECT ?, lesson_sets.digest, lesson_sets.schema_version, lesson_sets.canonical_bytes,
              lesson_sets.source, lesson_sets.created_at
            FROM lesson_sets
            JOIN run_learning_bindings ON run_learning_bindings.effective_digest = lesson_sets.digest
              AND run_learning_bindings.job_id = lesson_sets.job_id
            WHERE run_learning_bindings.run_id = ?
            """,
          arguments: [otherJob.id, runId]
        )
        try db.execute(
          sql: "UPDATE run_learning_bindings SET job_id = ? WHERE run_id = ?",
          arguments: [otherJob.id, runId]
        )
      }
      return
    }
    let mutation: String
    switch corruption {
    case .assignmentJob:
      mutation = "UPDATE trial_assignments SET job_id = job_id + 1 WHERE run_id = ?"
    case .assignmentEpoch:
      mutation = "UPDATE trial_assignments SET learning_epoch = learning_epoch + 1 WHERE run_id = ?"
    case .assignmentGeneration:
      mutation =
        "UPDATE trial_assignments SET trial_generation = trial_generation + 1 WHERE run_id = ?"
    case .bindingJob:
      preconditionFailure("binding job corruption returns after creating its referenced job")
    case .bindingEpoch:
      mutation =
        "UPDATE run_learning_bindings SET learning_epoch = learning_epoch + 1 WHERE run_id = ?"
    case .bindingTrial:
      mutation = "UPDATE run_learning_bindings SET trial_id = trial_id + 1 WHERE run_id = ?"
    case .bindingGeneration:
      mutation =
        "UPDATE run_learning_bindings SET trial_generation = trial_generation + 1 WHERE run_id = ?"
    case .bindingStableDigest:
      mutation =
        "UPDATE run_learning_bindings SET stable_digest = effective_digest WHERE run_id = ?"
    case .bindingEffectiveDigest:
      mutation =
        "UPDATE run_learning_bindings SET effective_digest = stable_digest WHERE run_id = ?"
    }
    try queue.write { db in
      try db.execute(sql: mutation, arguments: [runId])
    }
  }

  func apply(_ drift: LiveTrialStateDrift) throws {
    try queue.write { db in
      switch drift {
      case .stableDigest:
        try db.execute(
          sql: """
            UPDATE job_learning_state
            SET stable_lesson_set_digest = (
              SELECT replacement_digest FROM learning_candidates WHERE job_id = ?
            )
            WHERE job_id = ?
            """,
          arguments: [jobId, jobId]
        )
      case .stableRevision:
        try db.execute(
          sql: """
            UPDATE job_learning_state SET stable_revision = stable_revision + 1 WHERE job_id = ?
            """,
          arguments: [jobId]
        )
      }
    }
  }

  func apply(
    _ corruption: TrialSnapshotCorruption,
    runId: Int64,
    trialId: Int64
  ) throws {
    try queue.write { db in
      switch corruption {
      case .count:
        try db.execute(
          sql: "UPDATE learning_trials SET consumed_assignments = 2 WHERE trial_id = ?",
          arguments: [trialId]
        )
      case .assignmentJob:
        try db.execute(
          sql: "UPDATE trial_assignments SET job_id = job_id + 1 WHERE run_id = ?",
          arguments: [runId]
        )
      }
    }
  }

  func insertDuplicateLiveTrial(jobId: Int64) throws {
    try queue.write { db in
      try db.execute(sql: "DROP INDEX idx_learning_trials_live_job")
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, close_reason, algorithm)
          SELECT job_id, learning_epoch, base_digest, candidate_digest, generation + 1,
            admitted_at, assignment_deadline, decision_deadline, max_assignments, 0,
            cohort_cutoff, state, close_reason, algorithm
          FROM learning_trials WHERE job_id = ?
          """,
        arguments: [jobId]
      )
    }
  }

  func trialState(trialId: Int64) throws -> LearningTrialState? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT state FROM learning_trials WHERE trial_id = ?",
        arguments: [trialId]
      ).flatMap(LearningTrialState.init(rawValue:))
    }
  }
}
