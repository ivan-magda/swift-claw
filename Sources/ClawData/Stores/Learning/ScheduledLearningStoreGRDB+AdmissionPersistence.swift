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
    guard let state = LearningTrialState(rawValue: row["state"]) else {
      throw StoreError.unexpected("candidate admission trial is unreadable")
    }
    let algorithm = LearningAlgorithm(rawValue: row["algorithm"])
    return TrialRow(
      id: row["trial_id"],
      jobId: row["job_id"],
      epoch: LearningEpoch(row["learning_epoch"]),
      baseDigest: LessonSetDigest(rawValue: row["base_digest"]),
      candidateDigest: CandidateDigest(rawValue: row["candidate_digest"]),
      generation: row["generation"],
      state: state,
      algorithm: algorithm
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
      let inputsBytes = Data((row["inputs"] as String).utf8)
      let resultBytes = Data((row["result"] as String).utf8)
      guard
        (row["algorithm"] as String) == artifact.manifest.algorithm.rawValue,
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
