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
    guard trigger.algorithm == .v1 else {
      return nil
    }
    guard
      let state = try readState(db, jobId: trigger.jobId),
      state.epoch == trigger.epoch,
      state.stableDigest == trigger.stableDigest,
      state.feedbackRevision == trigger.feedbackRevision,
      try jobIsRepeatable(db, jobId: trigger.jobId),
      try liveTrial(db, jobId: trigger.jobId) == nil,
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
    let feedback = try reflectionFeedback(db, trigger: trigger, rows: rows)
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

  static func reflectionAuthorizationIsCurrent(
    _ db: Database,
    authorization: ReflectionAuthorization
  ) throws -> Bool {
    guard let current = try prepareReflection(db, trigger: authorization.trigger) else {
      return false
    }
    return ReflectionAuthorization(preparation: current) == authorization
  }

  static func jobIsRepeatable(_ db: Database, jobId: Int64) throws -> Bool {
    let row = try Row.fetchOne(
      db,
      sql: "SELECT status, recurrence FROM scheduled_jobs WHERE id = ?",
      arguments: [jobId]
    )
    guard
      let row,
      row["recurrence"] as String? != nil,
      let status = ScheduledJobStatus(rawValue: row["status"])
    else {
      return false
    }
    return status == .active || status == .paused
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
    rows: [ReflectionRow]
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
      arguments: [trigger.jobId, trigger.epoch.value, trigger.feedbackRevision.value]
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
        LessonSetSource.reflectorCandidate.rawValue,
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
    let inputs = NoCandidateInputs(
      triggerDigest: result.triggerDigest.rawValue,
      operationId: result.operationId.rawValue,
      carrierDigest: result.carrierDigest.rawValue
    )
    let receipt = NoCandidateReceipt(resultDigest: result.resultDigest.rawValue)
    let inputsBytes = try CanonicalJSON.data(encoding: inputs)
    let receiptBytes = try CanonicalJSON.data(encoding: receipt)
    // swiftlint:disable:next optional_data_string_conversion
    let inputsJSON = String(decoding: inputsBytes, as: UTF8.self)
    // swiftlint:disable:next optional_data_string_conversion
    let receiptJSON = String(decoding: receiptBytes, as: UTF8.self)
    try db.execute(
      sql: """
        INSERT INTO learning_decisions(kind, job_id, learning_epoch, inputs, result, algorithm,
          decided_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        NoCandidateReceipt.kind,
        jobId,
        epoch.value,
        inputsJSON,
        receiptJSON,
        result.algorithm.rawValue,
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
          SELECT job_id, replacement_digest, source_manifest
          FROM learning_candidates WHERE candidate_digest = ?
          """,
        arguments: [digest.rawValue]
      )
    else {
      return nil
    }
    let jobId: Int64 = row["job_id"]
    let replacementDigest = LessonSetDigest(rawValue: row["replacement_digest"])
    let manifestJSON: String = row["source_manifest"]
    guard
      let manifest = try? JSONDecoder().decode(
        CandidateSourceManifest.self,
        from: Data(manifestJSON.utf8)
      ),
      let replacement = try readLessonSet(db, jobId: jobId, digest: replacementDigest)
    else {
      throw StoreError.unexpected("candidate \(digest.rawValue) has an unreadable artifact")
    }
    let artifact = try CandidateArtifact(replacement: replacement, manifest: manifest)
    guard artifact.digest == digest else {
      throw StoreError.unexpected("candidate \(digest.rawValue) does not match its source bytes")
    }
    return artifact
  }

  private struct NoCandidateInputs: Encodable {
    let triggerDigest: String
    let operationId: String
    let carrierDigest: String

    enum CodingKeys: String, CodingKey {
      case triggerDigest = "trigger_digest"
      case operationId = "operation_id"
      case carrierDigest = "carrier_digest"
    }
  }

  private struct NoCandidateReceipt: Encodable {
    static let kind = "reflection_no_candidate"
    let resultDigest: String

    enum CodingKeys: String, CodingKey {
      case resultDigest = "result_digest"
    }
  }
}
