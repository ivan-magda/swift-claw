import ClawCore
import Foundation
import GRDB

// MARK: - Current Sources

extension ScheduledLearningStoreGRDB {
  static let hardVetoReason = "hard_veto"

  static func sourceBindingsAreCurrent(
    _ db: Database,
    artifact: CandidateArtifact,
    state: JobLearningState
  ) throws -> Bool {
    switch artifact.manifest.origin {
    case .reflection:
      guard let operation = try readOperation(db, id: artifact.manifest.operationId) else {
        return false
      }
      return try candidateIsCurrent(db, artifact: artifact, operation: operation)
    case .ownerApproval, .ownerEdit:
      guard let current = try currentPreparation(db, artifact: artifact, state: state) else {
        return false
      }
      return artifact.manifest.evidence == current.evidenceSources
        && artifact.manifest.evaluations == current.evaluationSources
        && artifact.manifest.feedback == current.feedbackSources
    }
  }

  static func currentPreparation(
    _ db: Database,
    artifact: CandidateArtifact,
    state: JobLearningState
  ) throws -> ReflectionPreparation? {
    let manifest = artifact.manifest
    guard let triggerFeedbackRevision = try triggerFeedbackRevision(db, artifact: artifact) else {
      return nil
    }
    let trigger = TriggerIdentity(
      jobId: manifest.jobId,
      epoch: manifest.epoch,
      algorithm: manifest.algorithm,
      stableDigest: manifest.baseDigest,
      evidenceDigests: manifest.evidence.map(\.digest),
      feedbackRevision: triggerFeedbackRevision,
      issueCodes: manifest.qualifyingIssueCodes,
      reason: manifest.triggerReason
    )
    guard
      trigger.digest == manifest.triggerDigest,
      let current = try prepareReflection(
        db,
        trigger: trigger,
        feedbackCutoff: state.feedbackRevision,
        requiredStateFeedbackRevision: state.feedbackRevision,
        requiresNoLiveTrial: false
      )
    else {
      return nil
    }
    return current.evidenceSources == manifest.evidence
      && current.evaluationSources == manifest.evaluations
      && current.feedbackSources == manifest.feedback
      ? current : nil
  }

  static func triggerFeedbackRevision(
    _ db: Database,
    artifact: CandidateArtifact
  ) throws -> FeedbackRevision? {
    var current = artifact
    var visited: Set<CandidateDigest> = []
    while current.manifest.origin != .reflection {
      guard
        visited.insert(current.digest).inserted,
        let predecessor = current.manifest.predecessorCandidate,
        let loaded = try readCandidateArtifact(db, digest: predecessor)
      else {
        return nil
      }
      current = loaded
    }
    return current.manifest.feedbackRevision
  }

  static func hardVetoes(
    _ db: Database,
    artifact: CandidateArtifact
  ) throws -> Set<HardVeto> {
    var vetoes: Set<HardVeto> = []
    if try hasEffectiveCandidateVeto(db, artifact: artifact) {
      vetoes.insert(.ownerDependencyRejected)
    }
    if try hasRequiredEvaluationDispute(db, artifact: artifact) {
      vetoes.insert(.ownerDependencyRejected)
    }
    return vetoes
  }

  static func hasEffectiveCandidateVeto(
    _ db: Database,
    artifact: CandidateArtifact
  ) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(
          SELECT 1 FROM feedback_events AS event
          WHERE event.job_id = ? AND event.learning_epoch = ?
            AND event.subject_kind = ? AND event.subject_digest = ?
            AND event.signal IN (?, ?)
            AND NOT EXISTS(
              SELECT 1 FROM feedback_events AS newer WHERE newer.supersedes = event.event_id
            )
        )
        """,
      arguments: [
        artifact.manifest.jobId,
        artifact.manifest.epoch.value,
        FeedbackSubjectKind.candidate.rawValue,
        artifact.digest.rawValue,
        OwnerSignal.candidateReject.rawValue,
        OwnerSignal.candidateEdit.rawValue,
      ]
    ) ?? false
  }

  static func hasRequiredEvaluationDispute(
    _ db: Database,
    artifact: CandidateArtifact
  ) throws -> Bool {
    for source in artifact.manifest.evidence where source.evaluationRequired {
      let disputed =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS(
              SELECT 1 FROM feedback_events AS event
              WHERE event.job_id = ? AND event.learning_epoch = ?
                AND event.subject_kind = ? AND event.subject_digest = ? AND event.signal = ?
                AND NOT EXISTS(
                  SELECT 1 FROM feedback_events AS newer WHERE newer.supersedes = event.event_id
                )
            )
            """,
          arguments: [
            artifact.manifest.jobId,
            artifact.manifest.epoch.value,
            FeedbackSubjectKind.evaluation.rawValue,
            source.evaluationDigest.rawValue,
            OwnerSignal.evaluationDispute.rawValue,
          ]
        ) ?? false
      if disputed {
        return true
      }
    }
    return false
  }
}

// MARK: - Owner Controls

extension ScheduledLearningStoreGRDB {
  static func candidateControl(
    _ db: Database,
    eventId: Int64,
    candidate: CandidateArtifact,
    signal: OwnerSignal,
    expectedPayload: Data?
  ) throws -> CandidateFeedbackSource? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT event_id, subject_kind, subject_digest, signal, payload, actor,
            transport_update_id, feedback_revision, supersedes, occurred_at
          FROM feedback_events AS event
          WHERE event_id = ? AND job_id = ? AND learning_epoch = ?
            AND NOT EXISTS(
              SELECT 1 FROM feedback_events AS newer WHERE newer.supersedes = event.event_id
            )
          """,
        arguments: [eventId, candidate.manifest.jobId, candidate.manifest.epoch.value]
      ),
      let subject = FeedbackSubjectKind(rawValue: row["subject_kind"]),
      let storedSignal = OwnerSignal(rawValue: row["signal"]),
      let actor = AuditActor(rawValue: row["actor"]),
      subject == .candidate,
      storedSignal == signal,
      actor == .owner,
      payloadMatches(row["payload"], expected: expectedPayload),
      (row["subject_digest"] as String) == candidate.digest.rawValue
    else {
      return nil
    }
    let revision = FeedbackRevision(row["feedback_revision"])
    return CandidateFeedbackSource(
      eventId: eventId,
      digest: try FeedbackEventDigest.of(
        eventId: eventId,
        jobId: candidate.manifest.jobId,
        epoch: candidate.manifest.epoch,
        subjectKind: subject,
        subjectDigest: row["subject_digest"],
        signal: storedSignal,
        payload: row["payload"],
        actor: actor,
        transportUpdateId: row["transport_update_id"],
        revision: revision,
        supersedes: row["supersedes"],
        occurredAtEpochSecond: row["occurred_at"]
      ),
      revision: revision,
      subjectKind: subject,
      subjectDigest: row["subject_digest"],
      signal: storedSignal
    )
  }

  static func payloadMatches(_ stored: String?, expected: Data?) -> Bool {
    switch (stored, expected) {
    case (nil, nil):
      true
    case (.some(let stored), .some(let expected)):
      Data(stored.utf8) == expected
    case (.none, .some), (.some, .none):
      false
    }
  }

  static func existingSuccessor(
    _ db: Database,
    predecessor: CandidateDigest,
    control: CandidateFeedbackSource,
    origin: CandidateOrigin
  ) throws -> CandidateArtifact? {
    let digests = try String.fetchAll(
      db,
      sql: """
        SELECT candidate_digest FROM learning_candidates
        WHERE predecessor_digest = ? AND origin = ? ORDER BY candidate_digest
        """,
      arguments: [predecessor.rawValue, origin.rawValue]
    )
    for raw in digests {
      let digest = CandidateDigest(rawValue: raw)
      guard let candidate = try readCandidateArtifact(db, digest: digest) else {
        continue
      }
      if candidate.manifest.predecessorFeedback == control {
        return candidate
      }
    }
    return nil
  }

  static func hasSuccessor(_ db: Database, predecessor: CandidateDigest) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS(SELECT 1 FROM learning_candidates WHERE predecessor_digest = ?)",
      arguments: [predecessor.rawValue]
    ) ?? false
  }

  static func closeCandidateTrial(
    _ db: Database,
    candidate: CandidateArtifact
  ) throws -> Int64? {
    let trialId = try Int64.fetchOne(
      db,
      sql: """
        UPDATE learning_trials SET state = ?, close_reason = ?
        WHERE candidate_digest = ? AND job_id = ? AND learning_epoch = ? AND state IN (?, ?)
        RETURNING trial_id
        """,
      arguments: [
        LearningTrialState.fellBack.rawValue,
        hardVetoReason,
        candidate.digest.rawValue,
        candidate.manifest.jobId,
        candidate.manifest.epoch.value,
        LearningTrialState.open.rawValue,
        LearningTrialState.draining.rawValue,
      ]
    )
    if let trialId {
      try db.execute(
        sql: """
          UPDATE job_learning_state SET open_trial_id = NULL
          WHERE job_id = ? AND learning_epoch = ? AND open_trial_id = ?
          """,
        arguments: [candidate.manifest.jobId, candidate.manifest.epoch.value, trialId]
      )
    }
    return trialId
  }
}
