import ClawCore
import Foundation
import GRDB

@testable import ClawData

enum CandidateTrialMismatch: CaseIterable {
  case job
  case epoch
  case candidateBase
  case stableBase
  case algorithm
  case replacement
  case currentState

  var expectedState: LearningTrialState {
    self == .currentState ? .promoted : .open
  }
}

enum EvaluationTrialMismatch: CaseIterable {
  case job
  case epoch
  case base
  case algorithm
}

enum TrialPointerState: CaseIterable {
  case absent
  case stale
}

extension FeedbackStoreEnvironment {
  struct Trial {
    let trialId: Int64
    let candidateDigest: String
    let replacementDigest: String
    let generation: Int
  }

  func seedOpenTrial() throws -> Trial {
    let replacement = try LessonSet.canonical(jobId: jobId, lessons: ["Prefer exact evidence."])
    let manifest = CandidateSourceManifest(
      origin: .reflection,
      algorithm: .v1,
      jobId: jobId,
      epoch: state.epoch,
      triggerDigest: TriggerDigest(rawValue: SHA256Digest.hex("feedback-trigger-\(jobId)")),
      triggerReason: .ownerCorrection,
      qualifyingIssueCodes: [],
      operationId: LearningOperationID(rawValue: "feedback-operation"),
      carrierDigest: CarrierDigest(rawValue: SHA256Digest.hex("feedback-carrier-\(jobId)")),
      resultDigest: ReflectionResultDigest(rawValue: SHA256Digest.hex("feedback-result-\(jobId)")),
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
    let generation = 3
    return try queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(
        db,
        artifact: artifact,
        now: now
      )
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, 3, 0, ?, ?, ?)
          """,
        arguments: [
          jobId,
          state.epoch.value,
          state.stableDigest.rawValue,
          artifact.digest.rawValue,
          generation,
          EpochSecondCodec.epoch(now),
          EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow)),
          EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.decisionWindow)),
          EpochSecondCodec.epoch(now),
          LearningTrialState.open.rawValue,
          LearningAlgorithm.v1.rawValue,
        ]
      )
      let trialId = db.lastInsertedRowID
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
          generation: generation
        ),
        algorithm: .v1,
        now: now
      )
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = ? WHERE job_id = ?",
        arguments: [trialId, jobId]
      )
      return Trial(
        trialId: trialId,
        candidateDigest: artifact.digest.rawValue,
        replacementDigest: replacement.digest.rawValue,
        generation: generation
      )
    }
  }

  func seedTypedOpenTrial(
    evaluationDigest: String,
    evaluationRequired: Bool,
    state trialState: LearningTrialState
  ) throws -> Trial {
    let replacement = try LessonSet.canonical(
      jobId: jobId,
      lessons: ["Prefer exact typed evidence."]
    )
    let evaluation = EvaluationDigest(rawValue: evaluationDigest)
    let evidence = CandidateEvidenceSource(
      runId: 91,
      digest: EvidenceDigest(rawValue: "evidence-91"),
      evaluationDigest: evaluation,
      evaluationRequired: evaluationRequired
    )
    let manifest = CandidateSourceManifest(
      origin: .reflection,
      algorithm: .v1,
      jobId: jobId,
      epoch: state.epoch,
      triggerDigest: TriggerDigest(rawValue: "typed-feedback-trigger"),
      triggerReason: .recurringIssue,
      qualifyingIssueCodes: ["typed.feedback"],
      operationId: LearningOperationID(rawValue: "typed-feedback-operation"),
      carrierDigest: CarrierDigest(rawValue: "typed-feedback-carrier"),
      resultDigest: ReflectionResultDigest(rawValue: "typed-feedback-result"),
      baseDigest: state.stableDigest,
      baseRevision: state.stableRevision,
      feedbackRevision: state.feedbackRevision,
      evidence: [evidence],
      evaluations: [CandidateEvaluationSource(runId: evidence.runId, digest: evaluation)],
      feedback: [],
      predecessorCandidate: nil,
      predecessorFeedback: nil
    )
    let artifact = try CandidateArtifact(replacement: replacement, manifest: manifest)
    let generation = 3
    return try queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(
        db,
        artifact: artifact,
        now: now
      )
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, 3, 0, ?, ?, ?)
          """,
        arguments: [
          jobId,
          state.epoch.value,
          state.stableDigest.rawValue,
          artifact.digest.rawValue,
          generation,
          EpochSecondCodec.epoch(now),
          EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow)),
          EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.decisionWindow)),
          EpochSecondCodec.epoch(now),
          trialState.rawValue,
          LearningAlgorithm.v1.rawValue,
        ]
      )
      let trialId = db.lastInsertedRowID
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
          generation: generation
        ),
        algorithm: .v1,
        now: now
      )
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = ? WHERE job_id = ?",
        arguments: [trialId, jobId]
      )
      return Trial(
        trialId: trialId,
        candidateDigest: artifact.digest.rawValue,
        replacementDigest: replacement.digest.rawValue,
        generation: generation
      )
    }
  }

  func setTrialPointer(_ state: TrialPointerState) throws {
    try queue.write { db in
      let pointer: Int64? = state == .absent ? nil : 999_999
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = ? WHERE job_id = ?",
        arguments: [pointer, jobId]
      )
    }
  }

  func trialState(_ trialId: Int64) throws -> LearningTrialState? {
    try queue.read { db in
      let raw = try String.fetchOne(
        db,
        sql: "SELECT state FROM learning_trials WHERE trial_id = ?",
        arguments: [trialId]
      )
      return raw.flatMap(LearningTrialState.init(rawValue:))
    }
  }

  func corruptCandidateManifest(candidateDigest: String) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE learning_candidates SET source_manifest = '{}' WHERE candidate_digest = ?",
        arguments: [candidateDigest]
      )
    }
  }

  func introduceTrialMismatch(_ mismatch: EvaluationTrialMismatch, trial: Trial) throws {
    let column: String
    let value: any DatabaseValueConvertible
    switch mismatch {
    case .job:
      column = "job_id"
      value = jobId + 1_000
    case .epoch:
      column = "learning_epoch"
      value = state.epoch.value + 1
    case .base:
      column = "base_digest"
      value = trial.replacementDigest
    case .algorithm:
      column = "algorithm"
      value = "stale-algorithm"
    }
    try queue.write { db in
      try db.execute(
        sql: "UPDATE learning_trials SET \(column) = ? WHERE trial_id = ?",
        arguments: [value, trial.trialId]
      )
    }
  }

  func introduceCandidateMismatch(_ mismatch: CandidateTrialMismatch, trial: Trial) throws {
    switch mismatch {
    case .job:
      try queue.write { db in
        let otherJobId = jobId + 1_000
        try db.execute(
          sql: """
            INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
              created_at)
            SELECT ?, digest, schema_version, canonical_bytes, source, created_at
            FROM lesson_sets WHERE job_id = ? AND digest = ?
            """,
          arguments: [otherJobId, jobId, trial.replacementDigest]
        )
        try db.execute(
          sql: "UPDATE learning_candidates SET job_id = ? WHERE candidate_digest = ?",
          arguments: [otherJobId, trial.candidateDigest]
        )
      }
    case .epoch:
      try updateCandidate(
        column: "learning_epoch",
        value: state.epoch.value + 1,
        digest: trial.candidateDigest
      )
    case .candidateBase:
      try updateCandidate(
        column: "base_digest",
        value: "stale-base",
        digest: trial.candidateDigest
      )
    case .stableBase:
      try queue.write { db in
        try db.execute(
          sql: "UPDATE job_learning_state SET stable_lesson_set_digest = ? WHERE job_id = ?",
          arguments: [trial.replacementDigest, jobId]
        )
      }
    case .algorithm:
      try updateCandidate(
        column: "algorithm",
        value: "stale-algorithm",
        digest: trial.candidateDigest
      )
    case .replacement:
      try updateWithForeignKeysDisabled(
        sql: "UPDATE learning_candidates SET replacement_digest = ? WHERE candidate_digest = ?",
        arguments: ["missing-replacement", trial.candidateDigest]
      )
    case .currentState:
      try queue.write { db in
        try db.execute(
          sql: "UPDATE learning_trials SET state = ? WHERE trial_id = ?",
          arguments: [LearningTrialState.promoted.rawValue, trial.trialId]
        )
      }
    }
  }

  func trialCloseReason(_ trialId: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT close_reason FROM learning_trials WHERE trial_id = ?",
        arguments: [trialId]
      )
    }
  }
}

// MARK: - Candidate Mutation

private extension FeedbackStoreEnvironment {
  func updateCandidate(
    column: String,
    value: (any DatabaseValueConvertible)?,
    digest: String
  ) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE learning_candidates SET \(column) = ? WHERE candidate_digest = ?",
        arguments: [value, digest]
      )
    }
  }

  func updateWithForeignKeysDisabled(
    sql: String,
    arguments: StatementArguments
  ) throws {
    try queue.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      do {
        try db.execute(sql: sql, arguments: arguments)
        try db.execute(sql: "PRAGMA foreign_keys = ON")
      } catch {
        try? db.execute(sql: "PRAGMA foreign_keys = ON")
        throw error
      }
    }
  }
}
