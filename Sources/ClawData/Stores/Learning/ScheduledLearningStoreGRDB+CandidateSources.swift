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
    guard
      let ancestry = try candidateAncestry(db, artifact: artifact),
      try candidateProvenanceIsValid(db, ancestry: ancestry, state: state),
      let current = try preparation(
        db,
        artifact: artifact,
        feedbackCutoff: state.feedbackRevision,
        state: state,
        triggerFeedbackRevision: ancestry.triggerFeedbackRevision
      )
    else {
      return false
    }
    return artifact.manifest.evidence == current.evidenceSources
      && artifact.manifest.evaluations == current.evaluationSources
      && artifact.manifest.feedback == current.feedbackSources
  }

  static func currentPreparation(
    _ db: Database,
    artifact: CandidateArtifact,
    state: JobLearningState
  ) throws -> ReflectionPreparation? {
    guard let ancestry = try candidateAncestry(db, artifact: artifact) else {
      return nil
    }
    return try preparation(
      db,
      artifact: artifact,
      feedbackCutoff: state.feedbackRevision,
      state: state,
      triggerFeedbackRevision: ancestry.triggerFeedbackRevision
    )
  }

  static func preparation(
    _ db: Database,
    artifact: CandidateArtifact,
    feedbackCutoff: FeedbackRevision,
    state: JobLearningState,
    triggerFeedbackRevision: FeedbackRevision
  ) throws -> ReflectionPreparation? {
    let manifest = artifact.manifest
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
        feedbackCutoff: feedbackCutoff,
        requiredStateFeedbackRevision: state.feedbackRevision,
        requiresNoLiveTrial: false
      )
    else {
      return nil
    }
    return current
  }

  struct CandidateAncestry {
    let rootToTip: [CandidateArtifact]
    let triggerFeedbackRevision: FeedbackRevision
  }

  static func candidateAncestry(
    _ db: Database,
    artifact: CandidateArtifact
  ) throws -> CandidateAncestry? {
    var current = artifact
    var tipToRoot: [CandidateArtifact] = []
    var visited: Set<CandidateDigest> = []
    while true {
      guard visited.insert(current.digest).inserted else {
        return nil
      }
      tipToRoot.append(current)
      if current.manifest.origin == .reflection {
        break
      }
      guard
        let predecessor = current.manifest.predecessorCandidate,
        let loaded = try readCandidateArtifact(db, digest: predecessor)
      else {
        return nil
      }
      current = loaded
    }
    return CandidateAncestry(
      rootToTip: tipToRoot.reversed(),
      triggerFeedbackRevision: current.manifest.feedbackRevision
    )
  }

  static func candidateProvenanceIsValid(
    _ db: Database,
    ancestry: CandidateAncestry,
    state: JobLearningState
  ) throws -> Bool {
    guard
      let root = ancestry.rootToTip.first,
      try reflectionProvenanceIsValid(
        db,
        artifact: root,
        state: state,
        triggerFeedbackRevision: ancestry.triggerFeedbackRevision
      )
    else {
      return false
    }
    for index in ancestry.rootToTip.indices.dropFirst() {
      guard
        try successorProvenanceIsValid(
          db,
          artifact: ancestry.rootToTip[index],
          predecessor: ancestry.rootToTip[ancestry.rootToTip.index(before: index)],
          state: state,
          triggerFeedbackRevision: ancestry.triggerFeedbackRevision
        )
      else {
        return false
      }
    }
    return true
  }

  static func reflectionProvenanceIsValid(
    _ db: Database,
    artifact: CandidateArtifact,
    state: JobLearningState,
    triggerFeedbackRevision: FeedbackRevision
  ) throws -> Bool {
    let manifest = artifact.manifest
    guard
      manifest.origin == .reflection,
      manifest.predecessorCandidate == nil,
      manifest.predecessorFeedback == nil,
      manifest.feedbackRevision == triggerFeedbackRevision,
      let operation = try readOperation(db, id: manifest.operationId),
      reflectionTrigger(artifact: artifact, operation: operation) != nil,
      let preparation = try preparation(
        db,
        artifact: artifact,
        feedbackCutoff: manifest.feedbackRevision,
        state: state,
        triggerFeedbackRevision: triggerFeedbackRevision
      )
    else {
      return false
    }
    return manifest.baseRevision == preparation.stableRevision
      && manifest.evidence == preparation.evidenceSources
      && manifest.evaluations == preparation.evaluationSources
      && manifest.feedback == preparation.feedbackSources
  }

  static func successorProvenanceIsValid(
    _ db: Database,
    artifact: CandidateArtifact,
    predecessor: CandidateArtifact,
    state: JobLearningState,
    triggerFeedbackRevision: FeedbackRevision
  ) throws -> Bool {
    let manifest = artifact.manifest
    guard
      let predecessorDigest = manifest.predecessorCandidate,
      let claimedControl = manifest.predecessorFeedback,
      predecessorDigest == predecessor.digest,
      predecessor.digest != artifact.digest,
      let storedControl = try storedCandidateControl(
        db,
        eventId: claimedControl.eventId,
        candidate: predecessor,
        signal: manifest.origin == .ownerApproval ? .candidateApprove : .candidateEdit
      ),
      storedControl.source == claimedControl,
      claimedControl.revision <= manifest.feedbackRevision,
      let preparation = try preparation(
        db,
        artifact: artifact,
        feedbackCutoff: manifest.feedbackRevision,
        state: state,
        triggerFeedbackRevision: triggerFeedbackRevision
      ),
      let expected = expectedSuccessor(
        artifact: artifact,
        predecessor: predecessor,
        control: storedControl,
        effectiveFeedback: preparation.feedbackSources
      )
    else {
      return false
    }
    return expected == artifact
  }

  static func expectedSuccessor(
    artifact: CandidateArtifact,
    predecessor: CandidateArtifact,
    control: StoredCandidateControl,
    effectiveFeedback: [CandidateFeedbackSource]
  ) -> CandidateArtifact? {
    let manifest = artifact.manifest
    do {
      switch manifest.origin {
      case .ownerApproval:
        guard control.payload == nil, artifact.replacement == predecessor.replacement else {
          return nil
        }
        return try CandidateSuccessorRules.approval(
          predecessor: predecessor,
          control: control.source,
          feedbackRevision: manifest.feedbackRevision,
          effectiveFeedback: effectiveFeedback
        )
      case .ownerEdit:
        guard
          let payload = control.payload,
          let lessons = CandidateEditPayload.decode(Data(payload.utf8)),
          let replacement = try? LessonSet.canonical(
            jobId: predecessor.manifest.jobId,
            lessons: lessons
          ),
          replacement == artifact.replacement
        else {
          return nil
        }
        return try CandidateSuccessorRules.edit(
          predecessor: predecessor,
          replacement: replacement,
          control: control.source,
          feedbackRevision: manifest.feedbackRevision,
          effectiveFeedback: effectiveFeedback
        )
      case .reflection:
        return nil
      }
    } catch {
      return nil
    }
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
  struct StoredCandidateControl {
    let source: CandidateFeedbackSource
    let payload: String?
  }

  static func candidateControl(
    _ db: Database,
    eventId: Int64,
    candidate: CandidateArtifact,
    signal: OwnerSignal,
    expectedPayload: Data?
  ) throws -> CandidateFeedbackSource? {
    guard
      let stored = try storedCandidateControl(
        db,
        eventId: eventId,
        candidate: candidate,
        signal: signal
      ),
      payloadMatches(stored.payload, expected: expectedPayload)
    else {
      return nil
    }
    return stored.source
  }

  static func storedCandidateControl(
    _ db: Database,
    eventId: Int64,
    candidate: CandidateArtifact,
    signal: OwnerSignal
  ) throws -> StoredCandidateControl? {
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
      (row["subject_digest"] as String) == candidate.digest.rawValue
    else {
      return nil
    }
    let revision = FeedbackRevision(row["feedback_revision"])
    return StoredCandidateControl(
      source: CandidateFeedbackSource(
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
      ),
      payload: row["payload"]
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
    candidate: CandidateArtifact,
    now: Date
  ) throws -> Int64? {
    guard let trial = try trialRow(db, candidate: candidate.digest),
      trial.state == .open || trial.state == .draining
    else {
      return nil
    }
    try terminalFallback(db, trialId: trial.id, now: now)
    return trial.id
  }
}
