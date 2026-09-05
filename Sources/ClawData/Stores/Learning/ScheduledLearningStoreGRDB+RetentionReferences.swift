import ClawCore
import Foundation
import GRDB

// MARK: - Live Roots

extension LearningRetentionSnapshot {
  func liveReferences(_ db: Database, now: Date) throws -> LearningRetentionReferences {
    var retained = LearningRetentionReferences()
    for state in states {
      let jobId: Int64 = state["job_id"]
      retained.lessons.insert(
        LearningRetentionLesson(jobId: jobId, digest: state["stable_lesson_set_digest"])
      )
      if let current = try ScheduledLearningStoreGRDB.readState(db, jobId: jobId),
        let promotion = try ScheduledLearningStoreGRDB.currentPromotion(db, state: current)
      {
        retained.decisions.insert(promotion.decisionId)
      }
    }
    for binding in bindings {
      let runId: Int64 = binding["run_id"]
      let settled = settlements.contains { row in
        (row["run_id"] as Int64) == runId && (row["settled_at"] as Int64?) != nil
      }
      if !settled { retained.runs.insert(runId) }
    }
    for trial in trials where isLiveTrial(trial) {
      retained.trials.insert(trial["trial_id"])
    }
    for candidate in candidates where candidateIsLive(candidate) {
      retained.candidates.insert(candidate["candidate_digest"])
    }
    let timestamp = EpochSecondCodec.epoch(now)
    for target in targets + challenges
    where (target["expires_at"] as Int64) >= timestamp
      && (target["consumed_at"] as Int64?) == nil
    {
      retainSubject(target, in: &retained)
    }
    for operation in operations {
      let state = LearningOperationState(rawValue: operation["state"])
      guard state == .pending || state == .claimed || state == .started else {
        continue
      }
      retained.operations.insert(operation["operation_id"])
      if (operation["phase"] as String) == LearningPhase.reflector.rawValue {
        // Before its result exists, a reflector has no candidate manifest. Its current job/epoch
        // evidence and feedback are the only durable superset of that in-flight carrier's sources.
        for row in evidence where sameJobEpoch(row, operation) {
          retained.runs.insert(row["run_id"])
        }
        for row in feedback where sameJobEpoch(row, operation) {
          retained.feedback.insert(row["event_id"])
        }
      }
    }
    return retained
  }

  func retainRecent(_ retained: inout LearningRetentionReferences, cutoff: Int64) {
    for row in settlements where (row["settled_at"] as Int64? ?? Int64.max) >= cutoff {
      retained.runs.insert(row["run_id"])
    }
    for row in evidence where (row["sealed_at"] as Int64) >= cutoff {
      retained.runs.insert(row["run_id"])
    }
    for row in evaluations where (row["created_at"] as Int64) >= cutoff {
      retained.runs.insert(row["run_id"])
    }
    for row in candidates where (row["created_at"] as Int64) >= cutoff {
      retained.candidates.insert(row["candidate_digest"])
    }
    for row in trials where (row["admitted_at"] as Int64) >= cutoff {
      retained.trials.insert(row["trial_id"])
    }
    for row in decisions where (row["decided_at"] as Int64) >= cutoff {
      retained.decisions.insert(row["decision_id"])
    }
    for row in operations where (row["created_at"] as Int64) >= cutoff {
      retained.operations.insert(row["operation_id"])
    }
    for row in feedback where (row["occurred_at"] as Int64) >= cutoff {
      retained.feedback.insert(row["event_id"])
    }
    for row in challenges where (row["expires_at"] as Int64) >= cutoff {
      retained.challenges.insert(row["challenge_id"])
    }
    for row in targets + challenges where (row["expires_at"] as Int64) >= cutoff {
      retainSubject(row, in: &retained)
    }
  }

  func retainResetBarrier(_ retained: inout LearningRetentionReferences) throws {
    for row in decisions where (row["kind"] as String) == ResetReceipt.kind {
      let result: LearningResetDecisionResult =
        try ScheduledLearningStoreGRDB.decodeCanonicalDecision(
          row["result"]
        )
      if states.contains(where: { state in
        sameJobEpoch(state, row)
          && (state["stable_revision"] as Int64) == result.newStableRevision.value
      }) {
        retained.decisions.insert(row["decision_id"])
      }
    }
  }

  func retainClosedReplacements(
    _ db: Database,
    _ retained: inout LearningRetentionReferences
  ) throws {
    for state in states {
      let jobId: Int64 = state["job_id"]
      var bases: Set<String> = [state["stable_lesson_set_digest"]]
      if let current = try ScheduledLearningStoreGRDB.readState(db, jobId: jobId),
        let promotion = try ScheduledLearningStoreGRDB.currentPromotion(db, state: current)
      {
        bases.insert(promotion.inputs.baseDigest.rawValue)
      }
      for trial in trials
      where !isLiveTrial(trial) && sameJobEpoch(state, trial)
        && bases.contains(trial["base_digest"])
      {
        guard
          let candidate = candidates.first(where: { candidate in
            (candidate["candidate_digest"] as String) == (trial["candidate_digest"] as String)
          })
        else {
          continue
        }
        // Admission's no-retry predicate also applies if the current promotion rolls back.
        // Its blocker needs identity rows, not obsolete source evidence and payloads.
        retained.trials.insert(trial["trial_id"])
        retained.candidates.insert(candidate["candidate_digest"])
        retained.lessons.insert(
          LearningRetentionLesson(jobId: jobId, digest: candidate["replacement_digest"])
        )
      }
    }
  }
}

// MARK: - Provenance Closure

extension LearningRetentionSnapshot {
  func expand(_ retained: inout LearningRetentionReferences) throws {
    var previous: LearningRetentionReferences
    repeat {
      previous = retained
      for trial in trials where retained.trials.contains(trial["trial_id"]) {
        retained.candidates.insert(trial["candidate_digest"])
        retained.lessons.insert(
          LearningRetentionLesson(jobId: trial["job_id"], digest: trial["base_digest"])
        )
      }
      for assignment in assignments {
        let runId: Int64 = assignment["run_id"]
        let trialId: Int64 = assignment["trial_id"]
        if retained.trials.contains(trialId) || retained.runs.contains(runId) {
          retained.runs.insert(runId)
          retained.trials.insert(trialId)
        }
      }
      try retainCandidateSources(&retained)
      try retainDecisionSources(&retained)
      retainRunSources(&retained)
      retainOperationSources(&retained)
      for challenge in challenges {
        if subjectIsRetained(challenge, retained: retained) {
          retained.challenges.insert(challenge["challenge_id"])
        }
        if retained.challenges.contains(challenge["challenge_id"]) {
          if let next: Int64 = challenge["superseded_by"] {
            retained.challenges.insert(next)
          }
        }
      }
      for event in feedback {
        if subjectIsRetained(event, retained: retained) {
          retained.feedback.insert(event["event_id"])
        }
        if retained.feedback.contains(event["event_id"]) {
          retainSubject(event, in: &retained)
          if let prior: Int64 = event["supersedes"] { retained.feedback.insert(prior) }
        }
      }
    } while previous != retained
  }

  func subjectIsRetained(_ row: Row, retained: LearningRetentionReferences) -> Bool {
    let digest: String = row["subject_digest"]
    switch FeedbackSubjectKind(rawValue: row["subject_kind"]) {
    case .run:
      return Int64(digest).map(retained.runs.contains) ?? false
    case .evaluation:
      return evaluations.contains { evaluation in
        sameJobEpoch(row, evaluation)
          && (evaluation["evaluation_digest"] as String) == digest
          && retained.runs.contains(evaluation["run_id"])
      }
    case .candidate:
      return retained.candidates.contains(digest)
    case .promotion:
      return Int64(digest).map(retained.decisions.contains) ?? false
    case nil:
      return false
    }
  }
}

// MARK: - Typed Source Edges

private extension LearningRetentionSnapshot {
  func retainCandidateSources(_ retained: inout LearningRetentionReferences) throws {
    for row in candidates where retained.candidates.contains(row["candidate_digest"]) {
      let manifest: CandidateSourceManifest =
        try ScheduledLearningStoreGRDB.decodeCanonicalDecision(
          row["source_manifest"]
        )
      retained.lessons.insert(
        LearningRetentionLesson(jobId: row["job_id"], digest: row["replacement_digest"])
      )
      retained.lessons.insert(
        LearningRetentionLesson(jobId: row["job_id"], digest: manifest.baseDigest.rawValue)
      )
      retained.runs.formUnion(manifest.evidence.map(\.runId))
      retained.runs.formUnion(manifest.evaluations.map(\.runId))
      retained.feedback.formUnion(manifest.feedback.map(\.eventId))
      retained.operations.insert(manifest.operationId.rawValue)
      if let predecessor = manifest.predecessorCandidate {
        retained.candidates.insert(predecessor.rawValue)
      }
      if let control = manifest.predecessorFeedback { retained.feedback.insert(control.eventId) }
      // A successor and notice target are also durable completion markers for the predecessor.
      for successor in candidates
      where (successor["predecessor_digest"] as String?) == (row["candidate_digest"] as String) {
        retained.candidates.insert(successor["candidate_digest"])
      }
    }
  }

  func retainDecisionSources(_ retained: inout LearningRetentionReferences) throws {
    for row in decisions {
      let id: Int64 = row["decision_id"]
      let kind: String = row["kind"]
      if kind == LearningDecisionKind.trial.rawValue
        || kind == LearningDecisionKind.rollback.rawValue
      {
        let receipt = try ScheduledLearningStoreGRDB.decodeTerminalReceipt(row)
        if retained.trials.contains(receipt.inputs.identity.trialId) {
          retained.decisions.insert(id)
        }
        guard retained.decisions.contains(id) else {
          continue
        }
        retained.trials.insert(receipt.inputs.identity.trialId)
        retained.candidates.insert(receipt.inputs.candidateDigest.rawValue)
        retained.runs.formUnion(receipt.cohort.map(\.runId))
        switch receipt.record.rollbackTrigger {
        case .ownerFeedback(let promotionId, let eventId),
          .supportWithdrawal(let promotionId, let eventId):
          retained.decisions.insert(promotionId)
          retained.feedback.insert(eventId)
        case .safety(let promotionId, _, _):
          retained.decisions.insert(promotionId)
        case .adapter(let promotionId, _, _):
          retained.decisions.insert(promotionId)
        case nil:
          break
        }
      } else if kind == AdmissionReceipt.kind {
        let receipt: AdmissionReceipt = try ScheduledLearningStoreGRDB.decodeCanonicalDecision(
          row["result"]
        )
        if retained.trials.contains(receipt.trialId) { retained.decisions.insert(id) }
        if retained.decisions.contains(id) {
          retained.trials.insert(receipt.trialId)
          retained.candidates.insert(receipt.candidateDigest.rawValue)
        }
      } else if kind == ReflectionNoCandidateReceipt.kind, retained.decisions.contains(id) {
        let inputs: ReflectionNoCandidateInputs =
          try ScheduledLearningStoreGRDB.decodeCanonicalDecision(
            row["inputs"]
          )
        retained.operations.insert(inputs.operationId.rawValue)
      } else if kind == ResetReceipt.kind, retained.decisions.contains(id) {
        let result: LearningResetDecisionResult =
          try ScheduledLearningStoreGRDB.decodeCanonicalDecision(
            row["result"]
          )
        retained.trials.formUnion(result.closedTrials.map(\.trialId))
        retained.operations.formUnion(result.staleNoCallOperationIds.map(\.rawValue))
        retained.operations.formUnion(result.inFlightOperationIds.map(\.rawValue))
      }
    }
  }

  func retainRunSources(_ retained: inout LearningRetentionReferences) {
    for row in bindings where retained.runs.contains(row["run_id"]) {
      retained.lessons.insert(
        LearningRetentionLesson(jobId: row["job_id"], digest: row["effective_digest"])
      )
      retained.lessons.insert(
        LearningRetentionLesson(jobId: row["job_id"], digest: row["stable_digest"])
      )
    }
    for row in evidence where retained.runs.contains(row["run_id"]) {
      for operation in operations
      where sameJobEpoch(row, operation)
        && (operation["source_digest"] as String) == (row["evidence_digest"] as String)
      {
        retained.operations.insert(operation["operation_id"])
      }
    }
  }

  func retainOperationSources(_ retained: inout LearningRetentionReferences) {
    for row in operations where retained.operations.contains(row["operation_id"]) {
      for sibling in operations
      where (sibling["key_digest"] as String?) == (row["key_digest"] as String?) {
        retained.operations.insert(sibling["operation_id"])
      }
      if (row["phase"] as String) == LearningPhase.evaluator.rawValue {
        for source in evidence
        where sameJobEpoch(row, source)
          && (row["source_digest"] as String) == (source["evidence_digest"] as String)
        {
          retained.runs.insert(source["run_id"])
        }
      }
    }
  }
}

// MARK: - Root Predicates

private extension LearningRetentionSnapshot {
  func isLiveTrial(_ row: Row) -> Bool {
    let state = LearningTrialState(rawValue: row["state"])
    return state == .open || state == .draining
  }

  func sameJobEpoch(_ lhs: Row, _ rhs: Row) -> Bool {
    (lhs["job_id"] as Int64) == (rhs["job_id"] as Int64)
      && (lhs["learning_epoch"] as Int64) == (rhs["learning_epoch"] as Int64)
  }

  func candidateIsLive(_ candidate: Row) -> Bool {
    let digest: String = candidate["candidate_digest"]
    return states.contains { state in
      sameJobEpoch(state, candidate)
        && (state["stable_lesson_set_digest"] as String) == (candidate["base_digest"] as String)
    }
      && !trials.contains { trial in
        (trial["candidate_digest"] as String) == digest
      }
      && !candidates.contains { successor in
        (successor["predecessor_digest"] as String?) == digest
      }
      && !feedback.contains { event in
        sameJobEpoch(event, candidate)
          && (event["subject_kind"] as String) == FeedbackSubjectKind.candidate.rawValue
          && (event["subject_digest"] as String) == digest
          && [OwnerSignal.candidateReject.rawValue, OwnerSignal.candidateEdit.rawValue]
            .contains(event["signal"])
      }
  }

  func retainSubject(_ row: Row, in retained: inout LearningRetentionReferences) {
    let digest: String = row["subject_digest"]
    switch FeedbackSubjectKind(rawValue: row["subject_kind"]) {
    case .run:
      if let runId = Int64(digest) { retained.runs.insert(runId) }
    case .evaluation:
      for evaluation in evaluations
      where sameJobEpoch(row, evaluation)
        && (evaluation["evaluation_digest"] as String) == digest
      {
        retained.runs.insert(evaluation["run_id"])
      }
    case .candidate:
      retained.candidates.insert(digest)
    case .promotion:
      if let id = Int64(digest) { retained.decisions.insert(id) }
    case nil:
      break
    }
  }
}
