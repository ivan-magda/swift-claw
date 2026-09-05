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

  struct ReducedReflectionRows {
    let prepared: [PreparedReflectionEvaluation]
    let effective: [EffectiveEvaluation]
    let events: [FeedbackEvent]
    let feedbackSources: [CandidateFeedbackSource]
    let payloads: [PreparedOwnerPayload]
    let vetoed: Bool
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
  ) throws -> [StoredFeedbackProjection] {
    var evaluationRuns: [String: Int64] = [:]
    for row in rows {
      guard evaluationRuns.updateValue(row.runId, forKey: row.evaluationDigest.rawValue) == nil
      else {
        throw StoreError.unexpected("reflection source has a duplicate evaluation digest")
      }
    }
    return try storedFeedback(
      db,
      jobId: trigger.jobId,
      epoch: trigger.epoch,
      runIds: Set(rows.map(\.runId)),
      evaluationRuns: evaluationRuns,
      cutoff: cutoff
    )
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
    feedback: [StoredFeedbackProjection],
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
    feedback: [StoredFeedbackProjection],
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
    feedback: [StoredFeedbackProjection],
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

// MARK: - No Candidate Receipt

extension ScheduledLearningStoreGRDB {
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
}

// MARK: - Workflow Trigger Discovery

extension ScheduledLearningStoreGRDB {
  public func workflowTriggers(jobId: Int64, now: Date) throws(StoreError) -> [TriggerIdentity] {
    try database.readMapping { db in
      guard let state = try Self.readState(db, jobId: jobId),
        try Self.jobIsRepeatable(db, jobId: jobId),
        try Self.liveTrial(db, jobId: jobId) == nil
      else {
        return []
      }
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT evidence_digest, compatibility_digest FROM (
            SELECT evaluation.evidence_digest, evaluation.compatibility_digest,
              ROW_NUMBER() OVER (PARTITION BY evaluation.compatibility_digest
                ORDER BY binding.occurrence_at DESC, binding.run_id DESC) AS position
            FROM learning_evaluations AS evaluation
            JOIN run_learning_bindings AS binding ON binding.run_id = evaluation.run_id
            WHERE evaluation.job_id = ? AND evaluation.learning_epoch = ?
              AND binding.stable_digest = ? AND binding.trial_id IS NULL
              AND binding.occurrence_at >= ? AND binding.occurrence_at <= ?
              AND evaluation.created_at <= ?
          ) WHERE position <= ? ORDER BY compatibility_digest, position DESC
          """,
        arguments: [
          jobId, state.epoch.value, state.stableDigest.rawValue,
          EpochSecondCodec.epoch(now.addingTimeInterval(-EvidenceWindow.maximumAge)),
          EpochSecondCodec.epoch(now), EpochSecondCodec.epoch(now), EvidenceWindow.maximumCount,
        ]
      )
      let grouped = Dictionary(grouping: rows) { row in
        row["compatibility_digest"] as String
      }
      return try grouped.keys.sorted().compactMap { compatibility in
        let digests = (grouped[compatibility] ?? []).map { row in
          EvidenceDigest(rawValue: row["evidence_digest"])
        }
        let snapshot = TriggerIdentity(
          jobId: jobId,
          epoch: state.epoch,
          algorithm: .v1,
          stableDigest: state.stableDigest,
          evidenceDigests: digests,
          feedbackRevision: state.feedbackRevision,
          issueCodes: [],
          reason: .recurringIssue
        )
        let sources = try Self.reflectionRows(db, trigger: snapshot)
        let feedback = try Self.reflectionFeedback(
          db,
          trigger: snapshot,
          rows: sources,
          cutoff: state.feedbackRevision
        )
        let reduced = try Self.reduceReflectionRows(sources, feedback: feedback, trigger: snapshot)
        guard reduced.vetoed == false else {
          return nil
        }
        let window = EvidenceWindow.select(
          from: reduced.effective,
          compatibility: CompatibilityDigest(rawValue: compatibility),
          cutoff: now
        )
        guard let trigger = LearningTrigger.detect(window: window, corrections: reduced.events),
          try Self.workflowReflectionIsClaimable(db, trigger: trigger),
          try Self.onlyControlsChangedSinceAttempt(db, trigger: trigger) == false
        else {
          return nil
        }
        return trigger
      }
    }
  }
}

// MARK: - Effective Trigger Changes

private extension ScheduledLearningStoreGRDB {
  static func workflowReflectionIsClaimable(_ db: Database, trigger: TriggerIdentity) throws -> Bool
  {
    let key = LearningOperationKey(
      jobId: trigger.jobId,
      epoch: trigger.epoch,
      phase: .reflector,
      sourceDigest: trigger.digest.rawValue,
      promptVersion: ReflectorPrompt.v1.version,
      schemaVersion: ReflectorOutput.currentSchemaVersion,
      rubricVersion: ReflectorRubric.v1
    )
    let raw = try String.fetchOne(
      db,
      sql: """
        SELECT state FROM learning_operations WHERE key_digest = ?
        ORDER BY attempt_generation DESC LIMIT 1
        """,
      arguments: [key.digest.rawValue]
    )
    return raw == nil || raw == LearningOperationState.pending.rawValue
      || raw == LearningOperationState.interruptedUnknown.rawValue
  }

  static func onlyControlsChangedSinceAttempt(_ db: Database, trigger: TriggerIdentity) throws
    -> Bool
  {
    let revisions = try Int64.fetchAll(
      db,
      sql: """
        SELECT feedback_revision - 1 FROM feedback_events
        WHERE job_id = ? AND learning_epoch = ? AND subject_kind IN (?, ?)
          AND feedback_revision > COALESCE((SELECT MAX(feedback_revision) FROM feedback_events
            WHERE job_id = ? AND learning_epoch = ? AND subject_kind NOT IN (?, ?)), 0)
          AND feedback_revision <= ? ORDER BY feedback_revision DESC
        """,
      arguments: [
        trigger.jobId, trigger.epoch.value,
        FeedbackSubjectKind.candidate.rawValue, FeedbackSubjectKind.promotion.rawValue,
        trigger.jobId, trigger.epoch.value,
        FeedbackSubjectKind.candidate.rawValue, FeedbackSubjectKind.promotion.rawValue,
        trigger.feedbackRevision.value,
      ]
    )
    for revision in revisions {
      let prior = TriggerIdentity(
        jobId: trigger.jobId,
        epoch: trigger.epoch,
        algorithm: trigger.algorithm,
        stableDigest: trigger.stableDigest,
        evidenceDigests: trigger.evidenceDigests,
        feedbackRevision: FeedbackRevision(revision),
        issueCodes: trigger.issueCodes,
        reason: trigger.reason
      )
      let key = LearningOperationKey(
        jobId: prior.jobId,
        epoch: prior.epoch,
        phase: .reflector,
        sourceDigest: prior.digest.rawValue,
        promptVersion: ReflectorPrompt.v1.version,
        schemaVersion: ReflectorOutput.currentSchemaVersion,
        rubricVersion: ReflectorRubric.v1
      )
      if try Bool.fetchOne(
        db,
        sql:
          "SELECT EXISTS(SELECT 1 FROM learning_operations WHERE key_digest = ?)",
        arguments: [key.digest.rawValue]
      ) == true {
        return true
      }
    }
    return false
  }
}
