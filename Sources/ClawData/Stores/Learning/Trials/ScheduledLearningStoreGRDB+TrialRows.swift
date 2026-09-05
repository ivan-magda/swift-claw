import ClawCore
import Foundation
import GRDB

// MARK: - Strict Trial Rows

extension ScheduledLearningStoreGRDB {
  static func trialRow(_ db: Database, trialId: Int64) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT trial_id, job_id, learning_epoch, base_digest, candidate_digest, generation,
          admitted_at, assignment_deadline, decision_deadline, max_assignments,
          consumed_assignments, cohort_cutoff, state, close_reason, algorithm
        FROM learning_trials WHERE trial_id = ?
        """,
      arguments: [trialId]
    )
  }

  static func strictTrial(
    _ db: Database,
    row: Row,
    currentState: JobLearningState?
  ) throws -> LearningTrial {
    guard
      let trialId = SQLiteStoredValue.int64(in: row, column: "trial_id"),
      trialId > 0,
      let jobId = SQLiteStoredValue.int64(in: row, column: "job_id"),
      jobId > 0,
      let epochRaw = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      epochRaw > 0,
      let baseRaw = SQLiteStoredValue.string(in: row, column: "base_digest"),
      isCanonicalDigest(baseRaw),
      let candidateRaw = SQLiteStoredValue.string(in: row, column: "candidate_digest"),
      isCanonicalDigest(candidateRaw),
      let generation = SQLiteStoredValue.int(in: row, column: "generation"),
      generation > 0,
      let admittedRaw = SQLiteStoredValue.int64(in: row, column: "admitted_at"),
      let admittedAt = EpochSecondCodec.date(fromEpoch: admittedRaw),
      let assignmentRaw = SQLiteStoredValue.int64(in: row, column: "assignment_deadline"),
      let assignmentDeadline = EpochSecondCodec.date(fromEpoch: assignmentRaw),
      let decisionRaw = SQLiteStoredValue.int64(in: row, column: "decision_deadline"),
      let decisionDeadline = EpochSecondCodec.date(fromEpoch: decisionRaw),
      let maximum = SQLiteStoredValue.int(in: row, column: "max_assignments"),
      maximum == TrialAdmissionPolicy.maximumAssignments,
      let consumed = SQLiteStoredValue.int(in: row, column: "consumed_assignments"),
      consumed >= 0,
      consumed <= maximum,
      let cutoffRaw = SQLiteStoredValue.int64(in: row, column: "cohort_cutoff"),
      let cohortCutoff = EpochSecondCodec.date(fromEpoch: cutoffRaw),
      cohortCutoff == admittedAt,
      assignmentDeadline
        == admittedAt.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow),
      decisionDeadline == admittedAt.addingTimeInterval(TrialAdmissionPolicy.decisionWindow),
      let stateRaw = SQLiteStoredValue.string(in: row, column: "state"),
      let state = LearningTrialState(rawValue: stateRaw),
      let closeReason = SQLiteStoredValue.nullableString(in: row, column: "close_reason"),
      let algorithmRaw = SQLiteStoredValue.string(in: row, column: "algorithm"),
      let algorithm = Optional(LearningAlgorithm(rawValue: algorithmRaw)),
      algorithm == .v1
    else {
      throw StoreError.unexpected("learning trial row is unreadable")
    }
    let epoch = LearningEpoch(epochRaw)
    let baseDigest = LessonSetDigest(rawValue: baseRaw)
    let candidateDigest = CandidateDigest(rawValue: candidateRaw)
    guard
      state == .open || state == .draining || closeReason.value != nil,
      (state == .open || state == .draining) == (closeReason.value == nil),
      let artifact = try readCandidateArtifact(db, digest: candidateDigest),
      artifact.manifest.jobId == jobId,
      artifact.manifest.epoch == epoch,
      artifact.manifest.baseDigest == baseDigest,
      artifact.manifest.algorithm == algorithm,
      artifact.replacement.jobId == jobId
    else {
      throw StoreError.unexpected("trial \(trialId) does not match its candidate artifact")
    }
    let admission = TrialRow(
      id: trialId,
      jobId: jobId,
      epoch: epoch,
      baseDigest: baseDigest,
      candidateDigest: candidateDigest,
      generation: generation,
      state: state,
      algorithm: algorithm
    )
    _ = try admissionReceipt(db, artifact: artifact, trial: admission)
    if let currentState {
      guard
        currentState.jobId == jobId,
        currentState.epoch == epoch,
        currentState.stableDigest == baseDigest,
        currentState.stableRevision == artifact.manifest.baseRevision
      else {
        throw StoreError.unexpected("live trial does not match current learning state")
      }
    }
    return LearningTrial(
      identity: LearningTrialIdentity(
        trialId: trialId,
        jobId: jobId,
        epoch: epoch,
        generation: generation
      ),
      baseDigest: baseDigest,
      baseRevision: artifact.manifest.baseRevision,
      candidateDigest: candidateDigest,
      replacementDigest: artifact.replacement.digest,
      algorithm: algorithm,
      admittedAt: admittedAt,
      cohortCutoff: cohortCutoff,
      maxAssignments: maximum,
      consumedAssignments: consumed,
      assignmentDeadline: assignmentDeadline,
      decisionDeadline: decisionDeadline,
      state: state,
      hardVetoes: try hardVetoes(db, artifact: artifact)
    )
  }
}
