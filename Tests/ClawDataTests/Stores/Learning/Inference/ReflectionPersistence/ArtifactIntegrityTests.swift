import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

extension ReflectionPersistenceTests {
  @Test(arguments: ManifestByteCorruption.allCases)
  func candidateArtifactRejectsChangedOrNonCanonicalManifestBytes(
    _ corruption: ManifestByteCorruption
  ) throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let operation = try env.startReflector(fixture)
    let baseline = try env.candidate(fixture: fixture, operation: operation)
    let schemaVersion =
      corruption == .wrongSchema
      ? CandidateSourceManifest.currentSchemaVersion + 1
      : CandidateSourceManifest.currentSchemaVersion
    let artifact = try artifactWithFeedback(baseline, schemaVersion: schemaVersion)
    try insertArtifactForReload(artifact, env: env)
    if corruption != .wrongSchema {
      let bytes = try corruptedManifestBytes(for: artifact, corruption: corruption)
      try replaceManifestBytes(bytes, digest: artifact.digest, env: env)
    }

    // when, then — Codable accepting unknown keys, a stale schema, or noncanonical bytes lets a
    // changed durable manifest collapse back onto the original trusted candidate identity
    #expect(throws: StoreError.self) {
      try env.learning.candidateArtifact(digest: artifact.digest)
    }
  }

  @Test(arguments: CandidateRowMismatch.allCases)
  func candidateArtifactRejectsManifestRowProjectionMismatch(
    _ mismatch: CandidateRowMismatch
  ) throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let operation = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: operation)
    try insertArtifactForReload(artifact, env: env)
    let lookup = try applyRowMismatch(mismatch, artifact: artifact, env: env)

    // when, then — omitting any denormalized projection comparison would let a corrupt row become
    // the admission handoff even though its immutable manifest describes another artifact
    #expect(throws: StoreError.self) {
      try env.learning.candidateArtifact(digest: lookup)
    }
  }
}

enum ManifestByteCorruption: CaseIterable, Sendable {
  case unknownTopLevel
  case unknownEvidence
  case unknownEvaluation
  case unknownFeedback
  case wrongSchema
  case nonCanonical
}

enum CandidateRowMismatch: CaseIterable, Sendable {
  case algorithm
  case epoch
  case baseDigest
  case baseRevision
  case feedbackRevision
  case origin
  case predecessor
  case replacementDigest
  case rowJob
  case manifestJob
  case candidateIdentity
}

// MARK: - Artifact Corruption Fixtures

private extension ReflectionPersistenceTests {
  func artifactWithFeedback(
    _ artifact: CandidateArtifact,
    schemaVersion: Int
  ) throws -> CandidateArtifact {
    let manifest = artifact.manifest
    let feedback = CandidateFeedbackSource(
      eventId: 91,
      digest: FeedbackEventDigest(rawValue: "feedback-event"),
      revision: manifest.feedbackRevision,
      subjectKind: .run,
      subjectDigest: String(manifest.evidence[0].runId),
      signal: .resultCorrection
    )
    return try CandidateArtifact(
      replacement: artifact.replacement,
      manifest: copyManifest(
        manifest,
        schemaVersion: schemaVersion,
        feedback: [feedback]
      )
    )
  }

  func insertArtifactForReload(
    _ artifact: CandidateArtifact,
    env: BoundRunEnvironment
  ) throws {
    try env.queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(db, artifact: artifact, now: env.now)
    }
  }

  func corruptedManifestBytes(
    for artifact: CandidateArtifact,
    corruption: ManifestByteCorruption
  ) throws -> Data {
    let original = try CanonicalJSON.data(encoding: artifact.manifest)
    if corruption == .nonCanonical {
      return original + Data(" ".utf8)
    }
    var object = try manifestObject(original)
    switch corruption {
    case .unknownTopLevel:
      object["unexpected"] = true
    case .unknownEvidence:
      var values = try nestedObjects(object, key: "evidence")
      values[0]["unexpected"] = true
      object["evidence"] = values
    case .unknownEvaluation:
      var values = try nestedObjects(object, key: "evaluations")
      values[0]["unexpected"] = true
      object["evaluations"] = values
    case .unknownFeedback:
      var values = try nestedObjects(object, key: "feedback")
      values[0]["unexpected"] = true
      object["feedback"] = values
    case .wrongSchema, .nonCanonical:
      throw ArtifactFixtureError.unsupportedCorruption
    }
    return try CanonicalJSON.data(fromJSONObject: object)
  }

  func manifestObject(_ bytes: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw ArtifactFixtureError.manifestIsNotAnObject
    }
    return object
  }

  func nestedObjects(
    _ object: [String: Any],
    key: String
  ) throws -> [[String: Any]] {
    guard let values = object[key] as? [[String: Any]], values.isEmpty == false else {
      throw ArtifactFixtureError.missingNestedObject(key)
    }
    return values
  }

  func replaceManifestBytes(
    _ bytes: Data,
    digest: CandidateDigest,
    env: BoundRunEnvironment
  ) throws {
    // swiftlint:disable:next optional_data_string_conversion
    let json = String(decoding: bytes, as: UTF8.self)
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE learning_candidates SET source_manifest = ? WHERE candidate_digest = ?",
        arguments: [json, digest.rawValue]
      )
    }
  }

  func applyRowMismatch(
    _ mismatch: CandidateRowMismatch,
    artifact: CandidateArtifact,
    env: BoundRunEnvironment
  ) throws -> CandidateDigest {
    switch mismatch {
    case .algorithm:
      try updateCandidateColumn(
        "algorithm",
        value: "scheduled-learning/v2",
        artifact: artifact,
        env: env
      )
    case .epoch:
      try updateCandidateColumn(
        "learning_epoch",
        value: artifact.manifest.epoch.value + 1,
        artifact: artifact,
        env: env
      )
    case .baseDigest:
      try updateCandidateColumn("base_digest", value: "changed-base", artifact: artifact, env: env)
    case .baseRevision:
      try updateCandidateColumn(
        "base_revision",
        value: artifact.manifest.baseRevision.value + 1,
        artifact: artifact,
        env: env
      )
    case .feedbackRevision:
      try updateCandidateColumn(
        "frozen_feedback_revision",
        value: artifact.manifest.feedbackRevision.value + 1,
        artifact: artifact,
        env: env
      )
    case .origin:
      try updateCandidateColumn(
        "origin",
        value: CandidateOrigin.ownerEdit.rawValue,
        artifact: artifact,
        env: env
      )
    case .predecessor:
      try updateCandidateColumn(
        "predecessor_digest",
        value: "changed-predecessor",
        artifact: artifact,
        env: env
      )
    case .replacementDigest:
      let replacement = try LessonSet.canonical(jobId: env.jobId, lessons: ["A different lesson."])
      try insertLessonSet(replacement, env: env)
      try updateCandidateColumn(
        "replacement_digest",
        value: replacement.digest.rawValue,
        artifact: artifact,
        env: env
      )
    case .rowJob:
      let otherJobId = env.jobId + 10_000
      let replacement = try LessonSet.canonical(
        jobId: otherJobId,
        lessons: artifact.replacement.lessons
      )
      try insertLessonSet(replacement, env: env)
      try updateCandidateColumn("job_id", value: otherJobId, artifact: artifact, env: env)
    case .manifestJob:
      let changedManifest = copyManifest(
        artifact.manifest,
        jobId: env.jobId + 20_000,
        feedback: artifact.manifest.feedback
      )
      let changedArtifact = try CandidateArtifact(
        replacement: artifact.replacement,
        manifest: changedManifest
      )
      let bytes = try CanonicalJSON.data(encoding: changedManifest)
      // swiftlint:disable:next optional_data_string_conversion
      let json = String(decoding: bytes, as: UTF8.self)
      try env.queue.write { db in
        try db.execute(
          sql: """
            UPDATE learning_candidates SET candidate_digest = ?, source_manifest = ?
            WHERE candidate_digest = ?
            """,
          arguments: [changedArtifact.digest.rawValue, json, artifact.digest.rawValue]
        )
      }
      return changedArtifact.digest
    case .candidateIdentity:
      let changed = CandidateDigest(rawValue: "changed-candidate-identity")
      try updateCandidateColumn(
        "candidate_digest",
        value: changed.rawValue,
        artifact: artifact,
        env: env
      )
      return changed
    }
    return artifact.digest
  }

  func updateCandidateColumn(
    _ column: String,
    value: some DatabaseValueConvertible,
    artifact: CandidateArtifact,
    env: BoundRunEnvironment
  ) throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE learning_candidates SET \(column) = ? WHERE candidate_digest = ?",
        arguments: [value, artifact.digest.rawValue]
      )
    }
  }

  func insertLessonSet(_ lessonSet: LessonSet, env: BoundRunEnvironment) throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          lessonSet.jobId,
          lessonSet.digest.rawValue,
          lessonSet.schemaVersion,
          lessonSet.canonicalBytes,
          LessonSetSource.reflectorCandidate.rawValue,
          EpochSecondCodec.epoch(env.now),
        ]
      )
    }
  }

  func copyManifest(
    _ manifest: CandidateSourceManifest,
    schemaVersion: Int? = nil,
    jobId: Int64? = nil,
    feedback: [CandidateFeedbackSource]
  ) -> CandidateSourceManifest {
    CandidateSourceManifest(
      schemaVersion: schemaVersion ?? manifest.schemaVersion,
      origin: manifest.origin,
      algorithm: manifest.algorithm,
      jobId: jobId ?? manifest.jobId,
      epoch: manifest.epoch,
      triggerDigest: manifest.triggerDigest,
      triggerReason: manifest.triggerReason,
      qualifyingIssueCodes: manifest.qualifyingIssueCodes,
      operationId: manifest.operationId,
      carrierDigest: manifest.carrierDigest,
      resultDigest: manifest.resultDigest,
      baseDigest: manifest.baseDigest,
      baseRevision: manifest.baseRevision,
      feedbackRevision: manifest.feedbackRevision,
      evidence: manifest.evidence,
      evaluations: manifest.evaluations,
      feedback: feedback,
      predecessorCandidate: manifest.predecessorCandidate,
      predecessorFeedback: manifest.predecessorFeedback
    )
  }
}

private enum ArtifactFixtureError: Error {
  case manifestIsNotAnObject
  case missingNestedObject(String)
  case unsupportedCorruption
}
