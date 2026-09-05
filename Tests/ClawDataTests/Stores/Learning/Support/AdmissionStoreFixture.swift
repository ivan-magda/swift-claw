import ClawCore
import ClawTestSupport
import Foundation
import GRDB

@testable import ClawData

struct AdmissionStoreFixture {
  struct TrialProjection {
    let candidate: String
    let admittedAt: Int64
    let assignmentDeadline: Int64
    let decisionDeadline: Int64
    let maximumAssignments: Int
    let consumedAssignments: Int
    let cohortCutoff: Int64
    let state: String
  }

  struct ReviewDelivery {
    let key: String
    let runId: Int64?
    let source: String
  }

  let path: String
  let env: BoundRunEnvironment

  static func make() throws -> AdmissionStoreFixture {
    let path = makeTempDatabasePath(prefix: "claw-learning-admission")
    return AdmissionStoreFixture(
      path: path,
      env: try BoundRunEnvironment.make(databasePath: path)
    )
  }

  func remove() {
    try? FileManager.default.removeItem(atPath: path)
  }

  func persistedCandidate(
    lessons: [String] = ["Report only material changes."]
  ) throws -> CandidateArtifact {
    let reflection = try env.reflectionFixture()
    let operation = try env.startReflector(reflection)
    let artifact = try env.candidate(
      fixture: reflection,
      operation: operation,
      lessons: lessons
    )
    guard
      try env.learning.finishOperation(
        env.reflectionResult(operation: operation, product: .candidate(artifact)),
        now: env.now
      )
    else {
      throw StoreError.unexpected("fixture candidate did not persist")
    }
    return artifact
  }

  func persistedCandidateWithFeedback() throws -> (CandidateArtifact, CandidateFeedbackSource) {
    try env.makeRepeatable()
    let first = try env.evaluatedEvidence(issueCode: "material.missed")
    let second = try env.evaluatedEvidence(issueCode: "material.missed")
    let source = try env.appendFeedback(
      subjectKind: .evaluation,
      subjectDigest: first.evaluation.digest.rawValue,
      signal: .evaluationConfirm
    )
    let state = try env.currentLearningState()
    let trigger = TriggerIdentity(
      jobId: env.jobId,
      epoch: state.epoch,
      algorithm: .v1,
      stableDigest: state.stableDigest,
      evidenceDigests: [first.evidence.digest, second.evidence.digest],
      feedbackRevision: state.feedbackRevision,
      issueCodes: ["material.missed"],
      reason: .recurringIssue
    )
    guard let preparation = try env.learning.prepareReflection(trigger: trigger) else {
      throw StoreError.unexpected("fixture feedback trigger did not prepare")
    }
    let reflection = BoundRunEnvironment.ReflectionFixture(
      trigger: trigger,
      preparation: preparation
    )
    let operation = try env.startReflector(reflection)
    let artifact = try env.candidate(fixture: reflection, operation: operation)
    guard
      try env.learning.finishOperation(
        env.reflectionResult(operation: operation, product: .candidate(artifact)),
        now: env.now
      )
    else {
      throw StoreError.unexpected("fixture feedback candidate did not persist")
    }
    return (artifact, source)
  }

  func trial(_ id: Int64) throws -> TrialProjection {
    let row = try env.queue.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT * FROM learning_trials WHERE trial_id = ?",
        arguments: [id]
      )
    }
    guard let row else {
      throw StoreError.unexpected("fixture trial is missing")
    }
    return TrialProjection(
      candidate: row["candidate_digest"],
      admittedAt: row["admitted_at"],
      assignmentDeadline: row["assignment_deadline"],
      decisionDeadline: row["decision_deadline"],
      maximumAssignments: row["max_assignments"],
      consumedAssignments: row["consumed_assignments"],
      cohortCutoff: row["cohort_cutoff"],
      state: row["state"]
    )
  }

  func admissionAuditCount() throws -> Int {
    try env.queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM audit_events WHERE action = ?",
        arguments: [AuditAction.learningCandidateAdmitted.rawValue]
      ) ?? -1
    }
  }

  func candidate(for digest: CandidateDigest) throws -> CandidateArtifact? {
    try env.learning.candidateArtifact(digest: digest)
  }

  func insertCompetingDrainingTrial(from artifact: CandidateArtifact) throws {
    let replacement = try LessonSet.canonical(
      jobId: env.jobId,
      lessons: ["Use a different exact source."]
    )
    let competitor = try CandidateArtifact(
      replacement: replacement,
      manifest: artifact.manifest
    )
    try env.queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(
        db,
        artifact: competitor,
        now: env.now
      )
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, 1, ?, ?, 1, ?, ?, ?, 3, 0, ?, ?, ?)
          """,
        arguments: [
          env.jobId,
          competitor.manifest.baseDigest.rawValue,
          competitor.digest.rawValue,
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(
            env.now.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow)
          ),
          EpochSecondCodec.epoch(
            env.now.addingTimeInterval(TrialAdmissionPolicy.decisionWindow)
          ),
          EpochSecondCodec.epoch(env.now),
          LearningTrialState.draining.rawValue,
          LearningAlgorithm.v1.rawValue,
        ]
      )
      let trialId = db.lastInsertedRowID
      try ScheduledLearningStoreGRDB.insertDecision(
        db,
        kind: AdmissionReceipt.kind,
        jobId: env.jobId,
        epoch: competitor.manifest.epoch,
        inputs: AdmissionDecisionInputs(candidateDigest: competitor.digest),
        result: AdmissionReceipt(
          candidateDigest: competitor.digest,
          replacementDigest: competitor.replacement.digest,
          trialId: trialId,
          generation: 1
        ),
        algorithm: .v1,
        now: env.now
      )
    }
  }

  func failAdmissionAudit() throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_admission_audit BEFORE INSERT ON audit_events
          WHEN NEW.action = '\(AuditAction.learningCandidateAdmitted.rawValue)'
          BEGIN SELECT RAISE(ABORT, 'forced audit failure'); END
          """
      )
    }
  }

  func failReviewTarget() throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_review_target BEFORE INSERT ON feedback_targets
          BEGIN SELECT RAISE(ABORT, 'forced target failure'); END
          """
      )
    }
  }

  func reviewDelivery() throws -> ReviewDelivery {
    let row = try env.queue.read { db in
      try Row.fetchOne(
        db,
        sql: """
          SELECT dedup_key, run_id, delivery_source FROM outbound_deliveries
          WHERE delivery_source = ?
          """,
        arguments: [DeliverySource.learning.rawValue]
      )
    }
    guard let row else {
      throw StoreError.unexpected("fixture review delivery is missing")
    }
    return ReviewDelivery(
      key: row["dedup_key"],
      runId: row["run_id"],
      source: row["delivery_source"]
    )
  }

  func review(
    candidate: CandidateArtifact,
    state: CandidateReviewState,
    now: Date,
    nonceSuffix: String = "first",
    candidateActions: [OwnerSignal]? = nil
  ) -> CandidateReviewNotice {
    let expiry = now.addingTimeInterval(2_592_000)
    let candidateIdentity = candidate.digest.rawValue.prefix(8)
    let actions =
      candidateActions
      ?? (state == .admitted
        ? [.candidateReject, .candidateEdit]
        : [.candidateApprove, .candidateReject, .candidateEdit])
    var targets = [
      NewFeedbackTarget(
        nonce: "candidate-\(nonceSuffix)-\(candidateIdentity)",
        jobId: candidate.manifest.jobId,
        epoch: candidate.manifest.epoch,
        subjectKind: .candidate,
        subjectDigest: candidate.digest.rawValue,
        allowedActions: actions,
        ownerUserId: 777,
        chatId: 777,
        expiresAt: expiry
      )
    ]
    targets += candidate.manifest.evaluations.enumerated().map { index, evaluation in
      NewFeedbackTarget(
        nonce: "evaluation-\(nonceSuffix)-\(index)-\(candidateIdentity)",
        jobId: candidate.manifest.jobId,
        epoch: candidate.manifest.epoch,
        subjectKind: .evaluation,
        subjectDigest: evaluation.digest.rawValue,
        allowedActions: [.evaluationConfirm, .evaluationDispute],
        ownerUserId: 777,
        chatId: 777,
        expiresAt: expiry
      )
    }
    let subject = CandidateReviewIdentity.digest(candidateDigest: candidate.digest)
    let payload = "Review this candidate."
    let markup = FeedbackKeyboard.candidateReviewMarkup(
      targets: targets,
      evaluations: candidate.manifest.evaluations
    )
    return CandidateReviewNotice(
      candidateDigest: candidate.digest,
      state: state,
      subjectDigest: subject,
      targets: targets,
      chunks: [
        LearningNoticeChunk(
          subjectDigest: subject,
          ordinal: 0,
          chatId: 777,
          payload: payload,
          payloadHash: ContentHash.fnv1a(payload),
          replyMarkup: markup
        )
      ]
    )
  }
}
