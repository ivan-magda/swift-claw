import ClawCore
import Foundation
import GRDB

// MARK: - Aggregate Preparation

extension ScheduledLearningStoreGRDB {
  public func prepareReflection(
    trigger: TriggerIdentity
  ) throws(StoreError) -> ReflectionPreparation? {
    try database.readMapping { db in
      try Self.prepareReflection(db, trigger: trigger)
    }
  }

  public func candidateArtifact(
    digest: CandidateDigest
  ) throws(StoreError) -> CandidateArtifact? {
    try database.readMapping { db in
      try Self.readCandidateArtifact(db, digest: digest)
    }
  }
}

// MARK: - Preparation Gate

extension ScheduledLearningStoreGRDB {
  static func prepareReflection(
    _ db: Database,
    trigger: TriggerIdentity
  ) throws -> ReflectionPreparation? {
    try prepareReflection(
      db,
      trigger: trigger,
      feedbackCutoff: trigger.feedbackRevision,
      requiredStateFeedbackRevision: trigger.feedbackRevision,
      requiresNoLiveTrial: true
    )
  }

  static func prepareReflection(
    _ db: Database,
    trigger: TriggerIdentity,
    feedbackCutoff: FeedbackRevision,
    requiredStateFeedbackRevision: FeedbackRevision,
    requiresNoLiveTrial: Bool
  ) throws -> ReflectionPreparation? {
    let trialRequirementIsMet =
      requiresNoLiveTrial == false
      ? true : try liveTrial(db, jobId: trigger.jobId) == nil
    guard trigger.algorithm == .v1 else {
      return nil
    }
    guard
      let state = try readState(db, jobId: trigger.jobId),
      state.epoch == trigger.epoch,
      state.stableDigest == trigger.stableDigest,
      state.feedbackRevision == requiredStateFeedbackRevision,
      try jobIsRepeatable(db, jobId: trigger.jobId),
      trialRequirementIsMet,
      let stable = try readLessonSet(db, jobId: trigger.jobId, digest: trigger.stableDigest)
    else {
      return nil
    }
    guard
      trigger.evidenceDigests.isEmpty == false,
      Set(trigger.evidenceDigests).count == trigger.evidenceDigests.count,
      trigger.evidenceDigests.count <= EvidenceWindow.maximumCount
    else {
      return nil
    }

    let rows = try reflectionRows(db, trigger: trigger)
    guard rows.count == trigger.evidenceDigests.count else {
      return nil
    }
    let feedback = try reflectionFeedback(
      db,
      trigger: trigger,
      rows: rows,
      cutoff: feedbackCutoff
    )
    let reduced = try reduceReflectionRows(rows, feedback: feedback, trigger: trigger)
    guard reduced.vetoed == false else {
      return nil
    }
    guard
      LearningTrigger.detect(window: reduced.effective, corrections: reduced.events) == trigger
    else {
      return nil
    }
    return ReflectionPreparation(
      trigger: trigger,
      stableLessons: stable,
      stableRevision: state.stableRevision,
      evaluations: reduced.prepared,
      feedbackSources: reduced.feedbackSources,
      ownerPayloads: reduced.payloads
    )
  }
}

// MARK: - Source Rows

private extension ScheduledLearningStoreGRDB {
  struct ReflectionRow {
    let runId: Int64
    let evidenceDigest: EvidenceDigest
    let evaluationDigest: EvaluationDigest
    let evaluatorOutcome: EvaluatorOutcome
    let issueCodes: [String]
    let compatibility: CompatibilityDigest
    let occurrenceAt: Date
    let evaluatedAt: Date
    let finalOutput: String
  }

  struct StoredReflectionFeedback {
    let event: FeedbackEvent
    let source: CandidateFeedbackSource
  }

  struct ReducedReflectionRows {
    let prepared: [PreparedReflectionEvaluation]
    let effective: [EffectiveEvaluation]
    let events: [FeedbackEvent]
    let feedbackSources: [CandidateFeedbackSource]
    let payloads: [PreparedOwnerPayload]
    let vetoed: Bool
  }

  struct ReflectionSubjects {
    let runIds: Set<String>
    let evaluationDigests: Set<String>
    let rows: [ReflectionRow]
  }

  static func reflectionRows(
    _ db: Database,
    trigger: TriggerIdentity
  ) throws -> [ReflectionRow] {
    var rows: [ReflectionRow] = []
    for evidenceDigest in trigger.evidenceDigests {
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT evaluation.evaluation_digest, evaluation.run_id, evaluation.outcome,
              evaluation.issue_codes, evaluation.compatibility_digest, evaluation.created_at,
              evidence.payload, binding.occurrence_at, binding.stable_digest, binding.trial_id
            FROM learning_evaluations AS evaluation
            JOIN learning_evidence AS evidence ON evidence.run_id = evaluation.run_id
              AND evidence.evidence_digest = evaluation.evidence_digest
            JOIN run_learning_bindings AS binding ON binding.run_id = evaluation.run_id
            WHERE evaluation.job_id = ? AND evaluation.learning_epoch = ?
              AND evaluation.evidence_digest = ?
            """,
          arguments: [trigger.jobId, trigger.epoch.value, evidenceDigest.rawValue]
        ),
        row["trial_id"] as Int64? == nil,
        (row["stable_digest"] as String) == trigger.stableDigest.rawValue,
        let outcome = EvaluatorOutcome(rawValue: row["outcome"]),
        let issueCodes = try? JSONDecoder().decode(
          [String].self,
          from: Data((row["issue_codes"] as String).utf8)
        ),
        let occurrenceAt = EpochSecondCodec.date(fromEpoch: row["occurrence_at"]),
        let evaluatedAt = EpochSecondCodec.date(fromEpoch: row["created_at"]),
        let payloadBytes: Data = row["payload"],
        let payload = try? JSONDecoder().decode(EvidencePayload.self, from: payloadBytes)
      else {
        return []
      }
      rows.append(
        ReflectionRow(
          runId: row["run_id"],
          evidenceDigest: evidenceDigest,
          evaluationDigest: EvaluationDigest(rawValue: row["evaluation_digest"]),
          evaluatorOutcome: outcome,
          issueCodes: issueCodes,
          compatibility: CompatibilityDigest(rawValue: row["compatibility_digest"]),
          occurrenceAt: occurrenceAt,
          evaluatedAt: evaluatedAt,
          finalOutput: payload.finalOutput
        )
      )
    }
    guard Set(rows.map(\.compatibility)).count == 1 else {
      return []
    }
    return rows
  }

  static func reflectionFeedback(
    _ db: Database,
    trigger: TriggerIdentity,
    rows: [ReflectionRow],
    cutoff: FeedbackRevision
  ) throws -> [StoredReflectionFeedback] {
    let subjects = ReflectionSubjects(
      runIds: Set(
        rows.map { row in
          String(row.runId)
        }
      ),
      evaluationDigests: Set(
        rows.map { row in
          row.evaluationDigest.rawValue
        }
      ),
      rows: rows
    )
    let stored = try Row.fetchAll(
      db,
      sql: """
          SELECT event_id, subject_kind, subject_digest, signal, payload, feedback_revision,
            supersedes, occurred_at, actor, transport_update_id
          FROM feedback_events
          WHERE job_id = ? AND learning_epoch = ? AND feedback_revision <= ?
          ORDER BY feedback_revision, event_id
        """,
      arguments: [trigger.jobId, trigger.epoch.value, cutoff.value]
    )
    return try stored.compactMap { row in
      try storedReflectionFeedback(row, trigger: trigger, subjects: subjects)
    }
  }

  static func storedReflectionFeedback(
    _ row: Row,
    trigger: TriggerIdentity,
    subjects: ReflectionSubjects
  ) throws -> StoredReflectionFeedback? {
    guard
      let subjectKind = FeedbackSubjectKind(rawValue: row["subject_kind"]),
      let signal = OwnerSignal(rawValue: row["signal"]),
      let occurredAt = EpochSecondCodec.date(fromEpoch: row["occurred_at"]),
      let actor = AuditActor(rawValue: row["actor"])
    else {
      throw StoreError.unexpected("reflection source holds an unreadable feedback event")
    }
    let subject: String = row["subject_digest"]
    let belongs =
      (subjectKind == .run && subjects.runIds.contains(subject))
      || (subjectKind == .evaluation && subjects.evaluationDigests.contains(subject))
    guard belongs else {
      return nil
    }
    let event = FeedbackEvent(
      id: row["event_id"],
      runId: runId(rows: subjects.rows, subjectKind: subjectKind, subject: subject),
      signal: signal,
      payload: row["payload"],
      revision: FeedbackRevision(row["feedback_revision"]),
      supersedes: row["supersedes"],
      occurredAt: occurredAt,
      actor: actor,
      transportUpdateId: row["transport_update_id"]
    )
    return StoredReflectionFeedback(
      event: event,
      source: CandidateFeedbackSource(
        eventId: event.id,
        digest: try FeedbackEventDigest.of(
          eventId: event.id,
          jobId: trigger.jobId,
          epoch: trigger.epoch,
          subjectKind: subjectKind,
          subjectDigest: subject,
          signal: signal,
          payload: event.payload,
          actor: actor,
          transportUpdateId: event.transportUpdateId,
          revision: event.revision,
          supersedes: event.supersedes,
          occurredAtEpochSecond: EpochSecondCodec.epoch(event.occurredAt)
        ),
        revision: event.revision,
        subjectKind: subjectKind,
        subjectDigest: subject,
        signal: signal
      )
    )
  }

  static func runId(
    rows: [ReflectionRow],
    subjectKind: FeedbackSubjectKind,
    subject: String
  ) -> Int64? {
    switch subjectKind {
    case .run:
      return Int64(subject)
    case .evaluation:
      return rows.first { row in
        row.evaluationDigest.rawValue == subject
      }?.runId
    case .candidate, .promotion:
      return nil
    }
  }
}

// MARK: - Effective Source Reduction

private extension ScheduledLearningStoreGRDB {
  struct ReducedReflectionRow {
    let prepared: PreparedReflectionEvaluation
    let effective: EffectiveEvaluation
    let feedbackSources: [CandidateFeedbackSource]
    let payload: PreparedOwnerPayload?
    let vetoed: Bool
  }

  static func reduceReflectionRows(
    _ rows: [ReflectionRow],
    feedback: [StoredReflectionFeedback],
    trigger: TriggerIdentity
  ) throws -> ReducedReflectionRows {
    let reduced = rows.map { row in
      let sources = feedback.filter { stored in
        stored.event.runId == row.runId
      }
      return reduceReflectionRow(row, feedback: sources, trigger: trigger)
    }
    var feedbackSources = reduced.flatMap(\.feedbackSources)
    var payloads = reduced.compactMap(\.payload)
    let events = feedback.map(\.event)
    feedbackSources.sort { lhs, rhs in
      (lhs.revision.value, lhs.eventId) < (rhs.revision.value, rhs.eventId)
    }
    payloads.sort { lhs, rhs in
      (lhs.source.revision.value, lhs.source.eventId)
        < (rhs.source.revision.value, rhs.source.eventId)
    }
    return ReducedReflectionRows(
      prepared: reduced.map(\.prepared),
      effective: reduced.map(\.effective),
      events: events,
      feedbackSources: feedbackSources,
      payloads: payloads,
      vetoed: reduced.contains(where: \.vetoed)
    )
  }

  static func reduceReflectionRow(
    _ row: ReflectionRow,
    feedback: [StoredReflectionFeedback],
    trigger: TriggerIdentity
  ) -> ReducedReflectionRow {
    let events = feedback.map(\.event)
    let outcome = OwnerPrecedence.resolve(
      evaluator: row.evaluatorOutcome,
      issueCodes: row.issueCodes,
      signals: events
    )
    let effectiveEvents = FeedbackEvent.unsuperseded(events)
    let feedbackSources = feedback.compactMap { source in
      effectiveEvents.contains(where: { event in
        event.id == source.event.id
      })
        ? source.source
        : nil
    }
    let correction = FeedbackEvent.latestUnsupersededResult(in: events)
    let payload = ownerPayload(
      for: correction,
      feedback: feedback,
      effectiveEvents: effectiveEvents
    )
    return ReducedReflectionRow(
      prepared: PreparedReflectionEvaluation(
        evidence: CandidateEvidenceSource(
          runId: row.runId,
          digest: row.evidenceDigest,
          evaluationDigest: row.evaluationDigest,
          evaluationRequired: outcome.evaluationRequired
        ),
        evaluation: CandidateEvaluationSource(runId: row.runId, digest: row.evaluationDigest),
        summary: ReflectorEvaluationSummary(
          runId: row.runId,
          finalOutput: row.finalOutput,
          outcome: outcome.outcome
        )
      ),
      effective: EffectiveEvaluation(
        runId: row.runId,
        jobId: trigger.jobId,
        epoch: trigger.epoch,
        stableDigest: trigger.stableDigest,
        evidenceDigest: row.evidenceDigest,
        compatibility: row.compatibility,
        occurrenceAt: row.occurrenceAt,
        evaluatorCompletedAt: row.evaluatedAt,
        trialId: nil,
        outcome: outcome.outcome,
        feedbackRevision: trigger.feedbackRevision
      ),
      feedbackSources: feedbackSources,
      payload: payload,
      vetoed: outcome.permitsDependentDecision == false
    )
  }

  static func ownerPayload(
    for correction: FeedbackEvent?,
    feedback: [StoredReflectionFeedback],
    effectiveEvents: [FeedbackEvent]
  ) -> PreparedOwnerPayload? {
    guard
      let correction,
      correction.signal == .resultCorrection,
      let body = correction.payload,
      let stored = feedback.first(where: { source in
        source.event.id == correction.id
      }),
      effectiveEvents.contains(where: { event in
        event.id == correction.id
      })
    else {
      return nil
    }
    return PreparedOwnerPayload(source: stored.source, payload: body)
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

  static func recordNoCandidate(
    _ db: Database,
    result: NoCandidateResult,
    jobId: Int64,
    epoch: LearningEpoch,
    now: Date
  ) throws {
    let inputs = ReflectionNoCandidateInputs(
      triggerDigest: result.triggerDigest,
      operationId: result.operationId,
      carrierDigest: result.carrierDigest
    )
    let receipt = ReflectionNoCandidateReceipt(resultDigest: result.resultDigest)
    try insertDecision(
      db,
      kind: ReflectionNoCandidateReceipt.kind,
      jobId: jobId,
      epoch: epoch,
      inputs: inputs,
      result: receipt,
      algorithm: result.algorithm,
      now: now
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
