import ClawCore
import Foundation
import GRDB

extension ScheduledLearningStoreGRDB {
  public func candidateArtifact(
    digest: CandidateDigest
  ) throws(StoreError) -> CandidateArtifact? {
    try database.readMapping { db in
      try Self.readCandidateArtifact(db, digest: digest)
    }
  }
}

// MARK: - Candidate Rows

extension ScheduledLearningStoreGRDB {
  static func recordCandidateArtifact(
    _ db: Database,
    artifact: CandidateArtifact,
    lessonSource: LessonSetSource = .reflectorCandidate,
    now: Date
  ) throws {
    let bytes = try CanonicalJSON.data(encoding: artifact.manifest)
    // swiftlint:disable:next optional_data_string_conversion
    let manifestJSON = String(decoding: bytes, as: UTF8.self)
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO lesson_sets(
          job_id, digest, schema_version, canonical_bytes, source, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        artifact.replacement.jobId,
        artifact.replacement.digest.rawValue,
        artifact.replacement.schemaVersion,
        artifact.replacement.canonicalBytes,
        lessonSource.rawValue,
        EpochSecondCodec.epoch(now),
      ]
    )
    guard
      let stored = try readLessonSet(
        db,
        jobId: artifact.replacement.jobId,
        digest: artifact.replacement.digest
      ),
      stored == artifact.replacement
    else {
      throw StoreError.unexpected("replacement digest resolved to different lesson bytes")
    }
    try db.execute(
      sql: """
        INSERT INTO learning_candidates(candidate_digest, job_id, learning_epoch,
          replacement_digest, base_digest, base_revision, frozen_feedback_revision, origin,
          source_manifest, predecessor_digest, algorithm, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        artifact.digest.rawValue,
        artifact.manifest.jobId,
        artifact.manifest.epoch.value,
        artifact.replacement.digest.rawValue,
        artifact.manifest.baseDigest.rawValue,
        artifact.manifest.baseRevision.value,
        artifact.manifest.feedbackRevision.value,
        artifact.manifest.origin.rawValue,
        manifestJSON,
        artifact.manifest.predecessorCandidate?.rawValue,
        artifact.manifest.algorithm.rawValue,
        EpochSecondCodec.epoch(now),
      ]
    )
  }

  static func readCandidateArtifact(
    _ db: Database,
    digest: CandidateDigest
  ) throws -> CandidateArtifact? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT candidate_digest, job_id, learning_epoch, replacement_digest, base_digest,
            base_revision, frozen_feedback_revision, origin, source_manifest, predecessor_digest,
            algorithm
          FROM learning_candidates WHERE candidate_digest = ?
          """,
        arguments: [digest.rawValue]
      )
    else {
      return nil
    }
    guard let stored = StoredCandidateProjection(row: row) else {
      throw StoreError.unexpected("candidate \(digest.rawValue) has an unreadable artifact")
    }
    let manifestBytes = Data(stored.manifestJSON.utf8)
    guard
      let manifest = CandidateSourceManifest.decodedCanonical(from: manifestBytes),
      let replacement = try readLessonSet(
        db,
        jobId: stored.jobId,
        digest: LessonSetDigest(rawValue: stored.replacementDigest)
      )
    else {
      throw StoreError.unexpected("candidate \(digest.rawValue) has an unreadable artifact")
    }
    let artifact = try CandidateArtifact(replacement: replacement, manifest: manifest)
    guard stored.matches(artifact: artifact, requestedDigest: digest) else {
      throw StoreError.unexpected("candidate \(digest.rawValue) does not match its source bytes")
    }
    return artifact
  }
}

private struct StoredCandidateProjection {
  let candidateDigest: String
  let jobId: Int64
  let epoch: Int64
  let replacementDigest: String
  let baseDigest: String
  let baseRevision: Int64
  let feedbackRevision: Int64
  let origin: String
  let manifestJSON: String
  let predecessorDigest: String?
  let algorithm: String

  init?(row: Row) {
    guard
      let candidateDigest = SQLiteStoredValue.string(in: row, column: "candidate_digest"),
      let jobId = SQLiteStoredValue.int64(in: row, column: "job_id"),
      let epoch = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      let replacementDigest = SQLiteStoredValue.string(in: row, column: "replacement_digest"),
      let baseDigest = SQLiteStoredValue.string(in: row, column: "base_digest"),
      let baseRevision = SQLiteStoredValue.int64(in: row, column: "base_revision"),
      let feedbackRevision = SQLiteStoredValue.int64(
        in: row,
        column: "frozen_feedback_revision"
      ),
      let origin = SQLiteStoredValue.string(in: row, column: "origin"),
      let manifestJSON = SQLiteStoredValue.string(in: row, column: "source_manifest"),
      let predecessor = SQLiteStoredValue.nullableString(in: row, column: "predecessor_digest"),
      let algorithm = SQLiteStoredValue.string(in: row, column: "algorithm")
    else {
      return nil
    }
    self.candidateDigest = candidateDigest
    self.jobId = jobId
    self.epoch = epoch
    self.replacementDigest = replacementDigest
    self.baseDigest = baseDigest
    self.baseRevision = baseRevision
    self.feedbackRevision = feedbackRevision
    self.origin = origin
    self.manifestJSON = manifestJSON
    predecessorDigest = predecessor.value
    self.algorithm = algorithm
  }

  func matches(
    artifact: CandidateArtifact,
    requestedDigest: CandidateDigest
  ) -> Bool {
    let manifest = artifact.manifest
    return candidateDigest == requestedDigest.rawValue
      && candidateDigest == artifact.digest.rawValue
      && jobId == artifact.replacement.jobId
      && jobId == manifest.jobId
      && epoch == manifest.epoch.value
      && replacementDigest == artifact.replacement.digest.rawValue
      && baseDigest == manifest.baseDigest.rawValue
      && baseRevision == manifest.baseRevision.value
      && feedbackRevision == manifest.feedbackRevision.value
      && origin == manifest.origin.rawValue
      && predecessorDigest == manifest.predecessorCandidate?.rawValue
      && algorithm == manifest.algorithm.rawValue
  }
}
