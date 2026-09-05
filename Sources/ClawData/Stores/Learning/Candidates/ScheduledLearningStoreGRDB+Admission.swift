import ClawCore
import Foundation
import GRDB

// MARK: - Candidate Admission

extension ScheduledLearningStoreGRDB {
  public func admitCandidate(
    digest: CandidateDigest,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome {
    try database.writeMapping { db in
      guard let artifact = try Self.readCandidateArtifact(db, digest: digest) else {
        return .rejected(.sourceBindingsChanged)
      }
      return try Self.admit(db, artifact: artifact, redactor: redactor, now: now)
    }
  }
}

// MARK: - Common Admission

extension ScheduledLearningStoreGRDB {
  enum AdmissionPlan {
    case replay(AdmissionReceipt)
    case awaitingApproval
    case insert(job: AdmissionJob, generation: Int)
    case rejected(AdmissionRejection)
  }

  static func admit(
    _ db: Database,
    artifact: CandidateArtifact,
    redactor: SecretRedactor,
    now: Date
  ) throws -> AdmissionOutcome {
    let plan = try planAdmission(db, artifact: artifact, persisted: true, redactor: redactor)
    return try executeAdmission(db, artifact: artifact, plan: plan, now: now)
  }

  static func planAdmission(
    _ db: Database,
    artifact: CandidateArtifact,
    persisted: Bool,
    redactor: SecretRedactor,
    permittedLiveCandidate: CandidateDigest? = nil,
    requiresSupport: Bool = true,
    permitsClosedReplacement: Bool = false
  ) throws -> AdmissionPlan {
    if persisted {
      guard
        let exact = try readCandidateArtifact(db, digest: artifact.digest),
        exact == artifact
      else {
        throw StoreError.unexpected("candidate changed during admission reload")
      }
    }
    if let existing = try trialRow(db, candidate: artifact.digest) {
      return .replay(try admissionReceipt(db, artifact: artifact, trial: existing))
    }
    guard try admissionDecisionExists(db, artifact: artifact) == false else {
      throw StoreError.unexpected("candidate admission decision has no matching trial")
    }
    guard
      let state = try readState(db, jobId: artifact.manifest.jobId),
      let job = try admissionJob(db, jobId: artifact.manifest.jobId)
    else {
      return .rejected(.jobNotRepeatable)
    }
    let live = try liveTrial(db, jobId: artifact.manifest.jobId)
    let hasCompetingLiveTrial =
      live.map { trial in
        trial.candidateDigest != permittedLiveCandidate
      } ?? false
    let sourcesCurrent = try sourceBindingsAreCurrent(db, artifact: artifact, state: state)
    let vetoes = try hardVetoes(db, artifact: artifact)
    let context = AdmissionValidationContext(
      currentState: state,
      jobHasRecurrence: job.hasRecurrence,
      jobStatus: job.status,
      hasLiveTrial: hasCompetingLiveTrial,
      sourceBindingsAreCurrent: sourcesCurrent,
      hardVetoes: vetoes,
      replacementAlreadyClosed: try replacementWasClosed(db, artifact: artifact),
      support: support(for: artifact),
      requiresSupport: requiresSupport,
      permitsClosedReplacement: permitsClosedReplacement,
      redactor: redactor
    )
    if let rejection = AdmissionValidator.validate(candidate: artifact, context: context) {
      return .rejected(rejection)
    }
    guard artifact.manifest.origin != .ownerEdit else {
      return .awaitingApproval
    }
    return .insert(job: job, generation: try nextGeneration(db, artifact: artifact))
  }

  static func executeAdmission(
    _ db: Database,
    artifact: CandidateArtifact,
    plan: AdmissionPlan,
    now: Date
  ) throws -> AdmissionOutcome {
    switch plan {
    case .replay(let receipt):
      return .admitted(receipt)
    case .awaitingApproval:
      return .awaitingApproval(artifact)
    case .insert(let job, let generation):
      return .admitted(
        try insertTrial(db, artifact: artifact, job: job, generation: generation, now: now)
      )
    case .rejected(let rejection):
      return .rejected(rejection)
    }
  }

  static func outcome(for plan: AdmissionPlan, artifact: CandidateArtifact) -> AdmissionOutcome {
    switch plan {
    case .replay(let receipt):
      return .admitted(receipt)
    case .awaitingApproval:
      return .awaitingApproval(artifact)
    case .rejected(let rejection):
      return .rejected(rejection)
    case .insert:
      return .rejected(.sourceBindingsChanged)
    }
  }
}

// MARK: - Trial Admission

private extension ScheduledLearningStoreGRDB {
  static func insertTrial(
    _ db: Database,
    artifact: CandidateArtifact,
    job: AdmissionJob,
    generation: Int,
    now: Date
  ) throws -> AdmissionReceipt {
    try db.execute(
      sql: """
        INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
          generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
          consumed_assignments, cohort_cutoff, state, algorithm)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
        """,
      arguments: [
        artifact.manifest.jobId,
        artifact.manifest.epoch.value,
        artifact.manifest.baseDigest.rawValue,
        artifact.digest.rawValue,
        generation,
        EpochSecondCodec.epoch(now),
        EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow)),
        EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.decisionWindow)),
        TrialAdmissionPolicy.maximumAssignments,
        EpochSecondCodec.epoch(now),
        LearningTrialState.open.rawValue,
        artifact.manifest.algorithm.rawValue,
      ]
    )
    let receipt = AdmissionReceipt(
      candidateDigest: artifact.digest,
      replacementDigest: artifact.replacement.digest,
      trialId: db.lastInsertedRowID,
      generation: generation
    )
    try db.execute(
      sql: """
        UPDATE job_learning_state SET open_trial_id = ?
        WHERE job_id = ? AND learning_epoch = ?
        """,
      arguments: [receipt.trialId, artifact.manifest.jobId, artifact.manifest.epoch.value]
    )
    try insertAdmissionReceipt(db, artifact: artifact, receipt: receipt, now: now)
    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: .system,
        action: .learningCandidateAdmitted,
        decision: "admitted",
        sessionId: job.sessionId,
        ts: now
      )
    )
    return receipt
  }

  static func support(for artifact: CandidateArtifact) -> AdmissionSupport? {
    switch artifact.manifest.origin {
    case .reflection:
      switch artifact.manifest.triggerReason {
      case .recurringIssue: .recurringIssue
      case .ownerCorrection: .ownerCorrection
      }
    case .ownerApproval:
      .ownerApproval
    case .ownerEdit:
      nil
    }
  }

  static func nextGeneration(_ db: Database, artifact: CandidateArtifact) throws -> Int {
    let latest =
      try Int.fetchOne(
        db,
        sql: """
          SELECT MAX(generation) FROM learning_trials
          WHERE job_id = ? AND learning_epoch = ?
          """,
        arguments: [artifact.manifest.jobId, artifact.manifest.epoch.value]
      ) ?? 0
    return latest + 1
  }

  static func replacementWasClosed(_ db: Database, artifact: CandidateArtifact) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(
          SELECT 1 FROM learning_trials AS trial
          JOIN learning_candidates AS candidate
            ON candidate.candidate_digest = trial.candidate_digest
          WHERE trial.job_id = ? AND trial.learning_epoch = ? AND trial.base_digest = ?
            AND candidate.replacement_digest = ? AND trial.algorithm = ?
            AND trial.state NOT IN (?, ?)
        )
        """,
      arguments: [
        artifact.manifest.jobId,
        artifact.manifest.epoch.value,
        artifact.manifest.baseDigest.rawValue,
        artifact.replacement.digest.rawValue,
        artifact.manifest.algorithm.rawValue,
        LearningTrialState.open.rawValue,
        LearningTrialState.draining.rawValue,
      ]
    ) ?? false
  }

  static func insertAdmissionReceipt(
    _ db: Database,
    artifact: CandidateArtifact,
    receipt: AdmissionReceipt,
    now: Date
  ) throws {
    try insertDecision(
      db,
      kind: AdmissionReceipt.kind,
      jobId: artifact.manifest.jobId,
      epoch: artifact.manifest.epoch,
      inputs: AdmissionDecisionInputs(candidateDigest: artifact.digest),
      result: receipt,
      algorithm: artifact.manifest.algorithm,
      now: now
    )
  }
}
