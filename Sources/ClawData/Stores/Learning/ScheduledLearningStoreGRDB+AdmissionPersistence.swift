import ClawCore
import Foundation
import GRDB

// MARK: - Admission Rows

extension ScheduledLearningStoreGRDB {
  struct AdmissionJob {
    let status: ScheduledJobStatus
    let hasRecurrence: Bool
    let sessionId: Int64?
    let ownerChatId: Int64
  }

  struct TrialRow {
    let id: Int64
    let jobId: Int64
    let epoch: LearningEpoch
    let baseDigest: LessonSetDigest
    let candidateDigest: CandidateDigest
    let generation: Int
    let state: LearningTrialState
    let algorithm: LearningAlgorithm
  }

  static func admissionJob(_ db: Database, jobId: Int64) throws -> AdmissionJob? {
    guard
      let row = try Row.fetchOne(
        db,
        sql:
          "SELECT status, recurrence, session_id, owner_chat_id FROM scheduled_jobs WHERE id = ?",
        arguments: [jobId]
      ),
      let status = ScheduledJobStatus(rawValue: row["status"])
    else {
      return nil
    }
    return AdmissionJob(
      status: status,
      hasRecurrence: (row["recurrence"] as String?) != nil,
      sessionId: row["session_id"],
      ownerChatId: row["owner_chat_id"]
    )
  }

  static func trialRow(_ db: Database, candidate: CandidateDigest) throws -> TrialRow? {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT trial_id, job_id, learning_epoch, base_digest, candidate_digest, generation,
          state, algorithm
        FROM learning_trials WHERE candidate_digest = ? ORDER BY trial_id
        """,
      arguments: [candidate.rawValue]
    )
    guard rows.count <= 1 else {
      throw StoreError.unexpected("candidate has multiple admission trials")
    }
    guard let row = rows.first else {
      return nil
    }
    guard
      let trialId = SQLiteStoredValue.int64(in: row, column: "trial_id"),
      let jobId = SQLiteStoredValue.int64(in: row, column: "job_id"),
      let epoch = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      let baseDigest = SQLiteStoredValue.string(in: row, column: "base_digest"),
      let candidateDigest = SQLiteStoredValue.string(in: row, column: "candidate_digest"),
      let generation = SQLiteStoredValue.int(in: row, column: "generation"),
      let stateRaw = SQLiteStoredValue.string(in: row, column: "state"),
      let state = LearningTrialState(rawValue: stateRaw),
      let algorithm = SQLiteStoredValue.string(in: row, column: "algorithm")
    else {
      throw StoreError.unexpected("candidate admission trial is unreadable")
    }
    return TrialRow(
      id: trialId,
      jobId: jobId,
      epoch: LearningEpoch(epoch),
      baseDigest: LessonSetDigest(rawValue: baseDigest),
      candidateDigest: CandidateDigest(rawValue: candidateDigest),
      generation: generation,
      state: state,
      algorithm: LearningAlgorithm(rawValue: algorithm)
    )
  }

  static func admissionReceipt(
    _ db: Database,
    artifact: CandidateArtifact,
    trial: TrialRow
  ) throws -> AdmissionReceipt {
    guard
      trial.jobId == artifact.manifest.jobId,
      trial.epoch == artifact.manifest.epoch,
      trial.baseDigest == artifact.manifest.baseDigest,
      trial.candidateDigest == artifact.digest,
      trial.algorithm == artifact.manifest.algorithm
    else {
      throw StoreError.unexpected("candidate admission trial identity is inconsistent")
    }
    let receipts = try admissionReceipts(db, artifact: artifact)
    guard receipts.count == 1, let receipt = receipts.first else {
      throw StoreError.unexpected("candidate admission receipt is missing or duplicated")
    }
    guard
      receipt.candidateDigest == artifact.digest,
      receipt.replacementDigest == artifact.replacement.digest,
      receipt.trialId == trial.id,
      receipt.generation == trial.generation
    else {
      throw StoreError.unexpected("candidate admission receipt identity is inconsistent")
    }
    return receipt
  }

  static func admissionDecisionExists(
    _ db: Database,
    artifact: CandidateArtifact
  ) throws -> Bool {
    try admissionReceipts(db, artifact: artifact).isEmpty == false
  }
}

private extension ScheduledLearningStoreGRDB {
  static func admissionReceipts(
    _ db: Database,
    artifact: CandidateArtifact
  ) throws -> [AdmissionReceipt] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT inputs, result, algorithm FROM learning_decisions
        WHERE kind = ? AND job_id = ? AND learning_epoch = ?
        ORDER BY decision_id
        """,
      arguments: [
        AdmissionReceipt.kind,
        artifact.manifest.jobId,
        artifact.manifest.epoch.value,
      ]
    )
    var matches: [AdmissionReceipt] = []
    for row in rows {
      guard
        let inputsJSON = SQLiteStoredValue.string(in: row, column: "inputs"),
        let resultJSON = SQLiteStoredValue.string(in: row, column: "result"),
        let algorithm = SQLiteStoredValue.string(in: row, column: "algorithm"),
        algorithm == artifact.manifest.algorithm.rawValue
      else {
        throw StoreError.unexpected("candidate admission decision is unreadable")
      }
      let inputsBytes = Data(inputsJSON.utf8)
      let resultBytes = Data(resultJSON.utf8)
      guard
        let inputs = try? JSONDecoder().decode(AdmissionDecisionInputs.self, from: inputsBytes),
        let receipt = try? JSONDecoder().decode(AdmissionReceipt.self, from: resultBytes),
        let canonicalInputs = try? CanonicalJSON.data(encoding: inputs),
        let canonicalResult = try? CanonicalJSON.data(encoding: receipt),
        canonicalInputs == inputsBytes,
        canonicalResult == resultBytes
      else {
        throw StoreError.unexpected("candidate admission decision is unreadable")
      }
      if inputs.candidateDigest == artifact.digest {
        matches.append(receipt)
      }
    }
    return matches
  }
}
