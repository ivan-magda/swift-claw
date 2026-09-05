import ClawCore
import Foundation
import GRDB

@testable import ClawData

enum ResetCurrentEpochActivity: CaseIterable {
  case binding
  case compatibility
  case evidence
  case operation
  case evaluation
  case target
  case challenge
  case feedbackEvent
  case candidate
  case trial
  case assignment
}

enum ResetDirtyEffect: CaseIterable {
  case liveTrial
  case target
  case challenge
  case pendingOperation
  case unlistedStartedOperation
}

enum ResetEmptyCollision: CaseIterable {
  case schemaVersion
  case canonicalBytes
  case source
}

enum ResetReceiptCorruption: CaseIterable {
  case noncanonicalJSON
  case wrongStableRevision
}

struct ResetFixture {
  struct OperationProjection: Equatable {
    let state: LearningOperationState
    let failure: LearningOperationFailure?
    let reservation: LearningReservationState?
    let reservedTokens: Int?
    let reservedCostUSD: Double?
    let route: String?
    let providerCallId: String?

    static let staleNoCall = OperationProjection(
      state: .failedNoCall,
      failure: .staleEpoch,
      reservation: .closed,
      reservedTokens: 0,
      reservedCostUSD: 0,
      route: nil,
      providerCallId: nil
    )

    static let started = OperationProjection(
      state: .started,
      failure: nil,
      reservation: .open,
      reservedTokens: 300,
      reservedCostUSD: 0.5,
      route: "route",
      providerCallId: "provider-secret-call"
    )

    static let claimed = OperationProjection(
      state: .claimed,
      failure: nil,
      reservation: nil,
      reservedTokens: nil,
      reservedCostUSD: nil,
      route: nil,
      providerCallId: nil
    )
  }

  struct AuditProjection {
    let actor: String
    let action: String
    let tool: String?
    let args: String
    let resultSize: Int
    let decision: String
    let runId: Int64?
    let sessionId: Int64?
  }

  let env: BoundRunEnvironment

  static func make() throws -> ResetFixture {
    ResetFixture(env: try BoundRunEnvironment.make())
  }

  func installStableLessons(_ lessons: [String]) throws -> LessonSet {
    _ = try env.learning.armJob(jobId: env.jobId, now: env.now)
    let set = try LessonSet.canonical(jobId: env.jobId, lessons: lessons)
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
            created_at) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          set.jobId,
          set.digest.rawValue,
          set.schemaVersion,
          set.canonicalBytes,
          LessonSetSource.reflectorCandidate.rawValue,
          EpochSecondCodec.epoch(env.now),
        ]
      )
      try db.execute(
        sql: """
          UPDATE job_learning_state SET stable_lesson_set_digest = ?, stable_revision = 4
          WHERE job_id = ?
          """,
        arguments: [set.digest.rawValue, env.jobId]
      )
    }
    return set
  }

  func setFeedbackRevision(_ revision: Int64) throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET feedback_revision = ? WHERE job_id = ?",
        arguments: [revision, env.jobId]
      )
    }
  }

  func seedOpenAndDrainingTrials(base: LessonSetDigest) throws -> [Int64] {
    try env.queue.write { db in
      var ids: [Int64] = []
      for (index, state) in [LearningTrialState.open, .draining].enumerated() {
        let candidateDigest = String(repeating: index == 0 ? "a" : "b", count: 64)
        let replacement = try LessonSet.canonical(
          jobId: env.jobId,
          lessons: ["replacement-\(index)"]
        )
        try db.execute(
          sql: """
            INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
              created_at) VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            env.jobId,
            replacement.digest.rawValue,
            replacement.schemaVersion,
            replacement.canonicalBytes,
            LessonSetSource.reflectorCandidate.rawValue,
            EpochSecondCodec.epoch(env.now),
          ]
        )
        try db.execute(
          sql: """
            INSERT INTO learning_candidates(candidate_digest, job_id, learning_epoch,
              replacement_digest, base_digest, base_revision, frozen_feedback_revision, origin,
              source_manifest, algorithm, created_at)
            VALUES (?, ?, 1, ?, ?, 4, 7, 'reflection', '{}', ?, ?)
            """,
          arguments: [
            candidateDigest,
            env.jobId,
            replacement.digest.rawValue,
            base.rawValue,
            LearningAlgorithm.v1.rawValue,
            EpochSecondCodec.epoch(env.now),
          ]
        )
        try db.execute(
          sql: """
            INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
              generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
              consumed_assignments, cohort_cutoff, state, algorithm)
            VALUES (?, 1, ?, ?, ?, ?, ?, ?, 3, 0, ?, ?, ?)
            """,
          arguments: [
            env.jobId,
            base.rawValue,
            candidateDigest,
            index + 1,
            EpochSecondCodec.epoch(env.now),
            EpochSecondCodec.epoch(env.now.addingTimeInterval(60)),
            EpochSecondCodec.epoch(env.now.addingTimeInterval(120)),
            EpochSecondCodec.epoch(env.now),
            state.rawValue,
            LearningAlgorithm.v1.rawValue,
          ]
        )
        ids.append(db.lastInsertedRowID)
      }
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = ? WHERE job_id = ?",
        arguments: [ids[0], env.jobId]
      )
      return ids
    }
  }

  func clearTrialPointer() throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = NULL WHERE job_id = ?",
        arguments: [env.jobId]
      )
    }
  }

  func corruptFirstLiveTrialBaseDigest() throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          UPDATE learning_trials SET base_digest = 'corrupt'
          WHERE trial_id = (
            SELECT trial_id FROM learning_trials WHERE job_id = ? ORDER BY trial_id LIMIT 1
          )
          """,
        arguments: [env.jobId]
      )
    }
  }

  func createOtherJob() throws -> Int64 {
    let job = try env.jobs.create(
      NewScheduledJob(
        ownerChatId: 888,
        label: "other",
        prompt: "Other job",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: env.now
      ),
      now: env.now
    )
    return job.id
  }

  func seedFeedbackControls(otherJobId: Int64) throws {
    try env.queue.write { db in
      for (nonce, jobId, epoch) in [
        ("target-secret-nonce-current", env.jobId, 1),
        ("target-secret-nonce-old", env.jobId, 0),
        ("target-secret-nonce-other", otherJobId, 1),
      ] {
        try db.execute(
          sql: """
            INSERT INTO feedback_targets(nonce, job_id, learning_epoch, subject_kind,
              subject_digest, allowed_actions, owner_user_id, chat_id, expires_at)
            VALUES (?, ?, ?, 'run', 'subject', '["result_useful"]', ?, ?, ?)
            """,
          arguments: [nonce, jobId, epoch, jobId + 100, jobId + 200, 1]
        )
      }
      for (owner, chat, jobId, epoch) in [
        (100, 200, env.jobId, 1),
        (101, 201, env.jobId, 0),
        (102, 202, otherJobId, 1),
      ] {
        try db.execute(
          sql: """
            INSERT INTO feedback_challenges(owner_user_id, chat_id, job_id, learning_epoch,
              subject_kind, subject_digest, expires_at)
            VALUES (?, ?, ?, ?, 'run', 'subject', 1)
            """,
          arguments: [owner, chat, jobId, epoch]
        )
      }
      try db.execute(
        sql: """
          INSERT INTO feedback_challenges(owner_user_id, chat_id, job_id, learning_epoch,
            subject_kind, subject_digest, expires_at)
          VALUES (103, 203, ?, 0, 'run', 'history', 1)
          """,
        arguments: [env.jobId]
      )
      let historyId = db.lastInsertedRowID
      try db.execute(
        sql: "UPDATE feedback_challenges SET superseded_by = ? WHERE challenge_id = ?",
        arguments: [historyId, historyId]
      )
    }
  }

  func seedOperations(otherJobId: Int64) throws {
    try env.queue.write { db in
      try insertOperation(db, id: "op-pending", jobId: env.jobId, state: .pending)
      try insertOperation(db, id: "op-claimed", jobId: env.jobId, state: .claimed)
      try insertOperation(db, id: "op-started", jobId: env.jobId, state: .started)
      try insertOperation(db, id: "op-other", jobId: otherJobId, state: .claimed)
    }
  }

  func insertOperation(
    _ db: Database,
    id: String,
    jobId: Int64,
    state: LearningOperationState
  ) throws {
    let started = state == .started
    try db.execute(
      sql: """
        INSERT INTO learning_operations(operation_id, job_id, learning_epoch, phase,
          source_digest, carrier_digest, route, provider_call_id, attempt_generation, state,
          reserved_tokens, reserved_cost_usd, reservation_state, created_at, key_digest)
        VALUES (?, ?, 1, 'evaluator', ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        id,
        jobId,
        "source-\(id)",
        started ? "carrier-\(id)" : nil,
        started ? "route" : nil,
        started ? "provider-secret-call" : nil,
        state.rawValue,
        started ? 300 : nil,
        started ? 0.5 : nil,
        started ? LearningReservationState.open.rawValue : nil,
        EpochSecondCodec.epoch(env.now),
        "key-\(id)",
      ]
    )
  }

  func state() throws -> JobLearningState {
    try env.currentLearningState()
  }

  func closedTrialIds() throws -> [Int64] {
    try trialIds(state: .closed)
  }

  func closedTrialReasons() throws -> [String] {
    try env.queue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT close_reason FROM learning_trials WHERE job_id = ? ORDER BY trial_id",
        arguments: [env.jobId]
      )
      return try rows.map { row in
        guard let reason = SQLiteStoredValue.string(in: row, column: "close_reason") else {
          throw StoreError.unexpected("fixture trial close reason is unreadable")
        }
        return reason
      }
    }
  }

  func liveTrialIds() throws -> [Int64] {
    try env.queue.read { db in
      try Int64.fetchAll(
        db,
        sql: """
          SELECT trial_id FROM learning_trials
          WHERE job_id = ? AND state IN (?, ?) ORDER BY trial_id
          """,
        arguments: [
          env.jobId,
          LearningTrialState.open.rawValue,
          LearningTrialState.draining.rawValue,
        ]
      )
    }
  }

  func trialIds(state: LearningTrialState) throws -> [Int64] {
    try env.queue.read { db in
      try Int64.fetchAll(
        db,
        sql: """
          SELECT trial_id FROM learning_trials
          WHERE job_id = ? AND state = ? ORDER BY trial_id
          """,
        arguments: [env.jobId, state.rawValue]
      )
    }
  }

  func unconsumedTargetCount(jobId: Int64) throws -> Int {
    try count(
      "feedback_targets",
      predicate: "job_id = ? AND consumed_at IS NULL",
      arguments: [jobId]
    )
  }

  func targetConsumptionEpochs(jobId: Int64) throws -> [Int64] {
    try consumptionEpochs(
      table: "feedback_targets",
      id: "nonce",
      predicate: "job_id = ?",
      arguments: [jobId]
    )
  }

  func liveChallengeCount(jobId: Int64) throws -> Int {
    try count(
      "feedback_challenges",
      predicate: "job_id = ? AND superseded_by IS NULL AND consumed_at IS NULL",
      arguments: [jobId]
    )
  }

  func challengeConsumptionEpochs(jobId: Int64) throws -> [Int64] {
    try consumptionEpochs(
      table: "feedback_challenges",
      id: "challenge_id",
      predicate: "job_id = ? AND superseded_by IS NULL",
      arguments: [jobId]
    )
  }

  func unconsumedSupersededChallengeCount() throws -> Int {
    try count(
      "feedback_challenges",
      predicate: "job_id = ? AND superseded_by IS NOT NULL AND consumed_at IS NULL",
      arguments: [env.jobId]
    )
  }

  func operation(_ id: String) throws -> OperationProjection? {
    try env.queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT state, failure_code, reservation_state, reserved_tokens, reserved_cost_usd,
              route, provider_call_id
            FROM learning_operations WHERE operation_id = ?
            """,
          arguments: [id]
        ),
        let state = LearningOperationState(rawValue: row["state"])
      else {
        return nil
      }
      let failureRaw: String? = row["failure_code"]
      let reservationRaw: String? = row["reservation_state"]
      return OperationProjection(
        state: state,
        failure: failureRaw.flatMap(LearningOperationFailure.init(rawValue:)),
        reservation: reservationRaw.flatMap(LearningReservationState.init(rawValue:)),
        reservedTokens: row["reserved_tokens"],
        reservedCostUSD: row["reserved_cost_usd"],
        route: row["route"],
        providerCallId: row["provider_call_id"]
      )
    }
  }

  func resetAudit() throws -> AuditProjection {
    let row = try env.queue.read { db in
      try Row.fetchOne(
        db,
        sql: """
          SELECT actor, action, tool, args_redacted, result_size, decision, run_id, session_id
          FROM audit_events WHERE action = ?
          """,
        arguments: [AuditAction.learningReset.rawValue]
      )
    }
    guard let row else {
      throw StoreError.unexpected("fixture reset audit is missing")
    }
    return AuditProjection(
      actor: row["actor"],
      action: row["action"],
      tool: row["tool"],
      args: row["args_redacted"],
      resultSize: row["result_size"],
      decision: row["decision"],
      runId: row["run_id"],
      sessionId: row["session_id"]
    )
  }

  func corruptCanonicalEmpty(_ collision: ResetEmptyCollision) throws {
    let empty = LessonSet.empty(jobId: env.jobId)
    try env.queue.write { db in
      switch collision {
      case .schemaVersion:
        try db.execute(
          sql: "UPDATE lesson_sets SET schema_version = ? WHERE job_id = ? AND digest = ?",
          arguments: [empty.schemaVersion + 1, env.jobId, empty.digest.rawValue]
        )
      case .canonicalBytes:
        try db.execute(
          sql: "UPDATE lesson_sets SET canonical_bytes = ? WHERE job_id = ? AND digest = ?",
          arguments: [Data("reset-corrupt".utf8), env.jobId, empty.digest.rawValue]
        )
      case .source:
        try db.execute(
          sql: "UPDATE lesson_sets SET source = ? WHERE job_id = ? AND digest = ?",
          arguments: [LessonSetSource.ownerEdit.rawValue, env.jobId, empty.digest.rawValue]
        )
      }
    }
  }

  func dropLearningStateTable() throws {
    try env.queue.write { db in
      try db.drop(table: "job_learning_state")
    }
  }

  func processed(updateId: Int64) throws -> Bool {
    try count("processed_updates", predicate: "update_id = ?", arguments: [updateId]) == 1
  }

  func resetDecisionCount() throws -> Int {
    try count(
      "learning_decisions",
      predicate: "kind = ?",
      arguments: [ResetReceipt.kind]
    )
  }

  func resetAuditCount() throws -> Int {
    try count(
      "audit_events",
      predicate: "action = ?",
      arguments: [AuditAction.learningReset.rawValue]
    )
  }

  func learningStateCount() throws -> Int {
    try count("job_learning_state", predicate: "1", arguments: [])
  }

  func lessonSetCount() throws -> Int {
    try count("lesson_sets", predicate: "1", arguments: [])
  }

  func failResetAudit() throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_reset_audit BEFORE INSERT ON audit_events
          WHEN NEW.action = '\(AuditAction.learningReset.rawValue)'
          BEGIN SELECT RAISE(ABORT, 'forced reset audit failure'); END
          """
      )
    }
  }

  func allowResetAudit() throws {
    try env.queue.write { db in
      try db.execute(sql: "DROP TRIGGER fail_reset_audit")
    }
  }

  func corruptResetResult(_ corruption: ResetReceiptCorruption) throws {
    try env.queue.write { db in
      let result = try String.fetchOne(
        db,
        sql: "SELECT result FROM learning_decisions WHERE kind = ?",
        arguments: [ResetReceipt.kind]
      )
      guard let result else {
        throw StoreError.unexpected("fixture reset decision is missing")
      }
      let corrupted: String
      switch corruption {
      case .noncanonicalJSON:
        corrupted = " \(result)"
      case .wrongStableRevision:
        let decoded: LearningResetDecisionResult =
          try ScheduledLearningStoreGRDB.decodeCanonicalDecision(result)
        let changed = LearningResetDecisionResult(
          newEpoch: decoded.newEpoch,
          emptyStableDigest: decoded.emptyStableDigest,
          newStableRevision: decoded.newStableRevision.next(),
          closedTrials: decoded.closedTrials,
          invalidatedTargetCount: decoded.invalidatedTargetCount,
          invalidatedChallengeCount: decoded.invalidatedChallengeCount,
          staleNoCallOperationIds: decoded.staleNoCallOperationIds,
          inFlightOperationIds: decoded.inFlightOperationIds
        )
        corrupted = try ScheduledLearningStoreGRDB.canonicalDecisionJSON(changed)
      }
      try db.execute(
        sql: "UPDATE learning_decisions SET result = ? WHERE kind = ?",
        arguments: [corrupted, ResetReceipt.kind]
      )
    }
  }

  func duplicateCurrentResetDecision() throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_decisions(kind, job_id, learning_epoch, inputs, result, algorithm,
            decided_at)
          SELECT kind, job_id, learning_epoch, inputs, result, algorithm, decided_at
          FROM learning_decisions WHERE kind = ? ORDER BY decision_id DESC LIMIT 1
          """,
        arguments: [ResetReceipt.kind]
      )
    }
  }

  func seedCurrentEpochActivity(_ activity: ResetCurrentEpochActivity) throws {
    let epoch = try state().epoch
    switch activity {
    case .binding:
      _ = try env.pendingBoundRun()
    case .compatibility:
      try seedCompatibility(epoch: epoch)
    case .evidence:
      try seedEvidence(epoch: epoch)
    case .operation:
      try env.queue.write { db in
        try insertOperation(
          db,
          id: "current-terminal-operation",
          jobId: env.jobId,
          epoch: epoch,
          state: .failed
        )
      }
    case .evaluation:
      try seedEvaluation(epoch: epoch)
    case .target:
      try seedTarget(epoch: epoch)
    case .challenge:
      try seedChallenge(epoch: epoch)
    case .feedbackEvent:
      try seedFeedbackEvent(epoch: epoch)
    case .candidate:
      _ = try seedCandidate(epoch: epoch)
    case .trial:
      try seedTrialActivity(epoch: epoch)
    case .assignment:
      try seedAssignmentActivity(epoch: epoch)
    }
  }

  func seedDirtyOldEpochEffect(_ effect: ResetDirtyEffect) throws {
    let oldEpoch = LearningEpoch(1)
    switch effect {
    case .liveTrial:
      let candidate = try seedCandidate(epoch: oldEpoch)
      try seedLiveTrial(candidate: candidate, epoch: oldEpoch)
    case .target:
      try seedTarget(epoch: oldEpoch, consumed: false)
    case .challenge:
      try seedChallenge(epoch: oldEpoch, consumed: false)
    case .pendingOperation:
      try env.queue.write { db in
        try insertOperation(
          db,
          id: "late-old-pending",
          jobId: env.jobId,
          epoch: oldEpoch,
          state: .pending
        )
      }
    case .unlistedStartedOperation:
      try env.queue.write { db in
        try insertStartedOperation(
          db,
          id: "late-old-started",
          jobId: env.jobId,
          epoch: oldEpoch
        )
      }
    }
  }

  func consumptionEpochs(
    table: String,
    id: String,
    predicate: String,
    arguments: StatementArguments
  ) throws -> [Int64] {
    try env.queue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT consumed_at FROM \(table) WHERE \(predicate) ORDER BY \(id)",
        arguments: arguments
      )
      return try rows.map { row in
        guard let epoch = SQLiteStoredValue.int64(in: row, column: "consumed_at") else {
          throw StoreError.unexpected("fixture consumption time is unreadable")
        }
        return epoch
      }
    }
  }

  func count(
    _ table: String,
    predicate: String,
    arguments: StatementArguments
  ) throws -> Int {
    try env.queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM \(table) WHERE \(predicate)",
        arguments: arguments
      ) ?? -1
    }
  }
}

// MARK: - Current-Epoch Activity Fixtures

private extension ResetFixture {
  func insertOperation(
    _ db: Database,
    id: String,
    jobId: Int64,
    epoch: LearningEpoch,
    state: LearningOperationState
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO learning_operations(operation_id, job_id, learning_epoch, phase,
          source_digest, attempt_generation, state, created_at, key_digest)
        VALUES (?, ?, ?, 'evaluator', ?, 1, ?, ?, ?)
        """,
      arguments: [
        id,
        jobId,
        epoch.value,
        "source-\(id)",
        state.rawValue,
        EpochSecondCodec.epoch(env.now),
        "key-\(id)",
      ]
    )
  }

  func seedCompatibility(epoch: LearningEpoch) throws {
    let runId = try env.unboundRun()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO run_compatibility(run_id, job_id, learning_epoch)
          VALUES (?, ?, ?)
          """,
        arguments: [runId, env.jobId, epoch.value]
      )
    }
  }

  func seedEvidence(epoch: LearningEpoch) throws {
    let runId = try env.unboundRun()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_evidence(run_id, job_id, learning_epoch, evidence_digest,
            eligibility, classifier_version, sealed_at)
          VALUES (?, ?, ?, 'current-evidence', 'insufficient_evidence', '1', ?)
          """,
        arguments: [runId, env.jobId, epoch.value, EpochSecondCodec.epoch(env.now)]
      )
    }
  }

  func seedEvaluation(epoch: LearningEpoch) throws {
    let runId = try env.unboundRun()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_evaluations(evaluation_digest, job_id, learning_epoch, run_id,
            evidence_digest, outcome, issue_codes, rubric_version, evaluator_prompt_version,
            evaluator_schema_version, compatibility_digest, created_at)
          VALUES ('current-evaluation', ?, ?, ?, 'evidence', 'no_issue', '[]', '1', '1', '1',
            'compatibility', ?)
          """,
        arguments: [env.jobId, epoch.value, runId, EpochSecondCodec.epoch(env.now)]
      )
    }
  }

  func seedTarget(epoch: LearningEpoch, consumed: Bool = true) throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO feedback_targets(nonce, job_id, learning_epoch, subject_kind,
            subject_digest, allowed_actions, owner_user_id, chat_id, expires_at, consumed_at)
          VALUES (?, ?, ?, 'run', 'subject', '["result_useful"]', 1, 1, 1, ?)
          """,
        arguments: [
          consumed ? "current-consumed-target" : "late-old-live-target",
          env.jobId,
          epoch.value,
          consumed ? 1 : nil,
        ]
      )
    }
  }

  func seedChallenge(epoch: LearningEpoch, consumed: Bool = true) throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO feedback_challenges(owner_user_id, chat_id, job_id, learning_epoch,
            subject_kind, subject_digest, consumed_at, expires_at)
          VALUES (?, ?, ?, ?, 'run', 'subject', ?, 1)
          """,
        arguments: [
          consumed ? 1 : 2,
          consumed ? 1 : 2,
          env.jobId,
          epoch.value,
          consumed ? 1 : nil,
        ]
      )
    }
  }

  func seedFeedbackEvent(epoch: LearningEpoch) throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO feedback_events(job_id, learning_epoch, subject_kind, subject_digest,
            signal, actor, feedback_revision, occurred_at)
          VALUES (?, ?, 'run', 'subject', 'result_useful', 'owner', 1, 1)
          """,
        arguments: [env.jobId, epoch.value]
      )
    }
  }

  func seedCandidate(epoch: LearningEpoch) throws -> String {
    let digest = String(repeating: "c", count: 64)
    let replacement = try LessonSet.canonical(jobId: env.jobId, lessons: ["current candidate"])
    let state = try state()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO lesson_sets(job_id, digest, schema_version, canonical_bytes,
            source, created_at) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          env.jobId,
          replacement.digest.rawValue,
          replacement.schemaVersion,
          replacement.canonicalBytes,
          LessonSetSource.reflectorCandidate.rawValue,
          EpochSecondCodec.epoch(env.now),
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO learning_candidates(candidate_digest, job_id, learning_epoch,
            replacement_digest, base_digest, base_revision, frozen_feedback_revision, origin,
            source_manifest, algorithm, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, 'reflection', '{}', ?, ?)
          """,
        arguments: [
          digest,
          env.jobId,
          epoch.value,
          replacement.digest.rawValue,
          state.stableDigest.rawValue,
          state.stableRevision.value,
          state.feedbackRevision.value,
          LearningAlgorithm.v1.rawValue,
          EpochSecondCodec.epoch(env.now),
        ]
      )
    }
    return digest
  }

  func seedTrialActivity(epoch: LearningEpoch) throws {
    let candidate = try seedCandidate(epoch: LearningEpoch(epoch.value - 1))
    _ = try seedClosedTrial(candidate: candidate, epoch: epoch)
  }

  func seedAssignmentActivity(epoch: LearningEpoch) throws {
    let candidate = try seedCandidate(epoch: LearningEpoch(epoch.value - 1))
    let trialId = try seedClosedTrial(
      candidate: candidate,
      epoch: LearningEpoch(epoch.value - 1)
    )
    let runId = try env.unboundRun()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO trial_assignments(run_id, trial_id, job_id, learning_epoch,
            trial_generation, assigned_at, state, evaluation_required)
          VALUES (?, ?, ?, ?, 1, ?, 'created', 1)
          """,
        arguments: [
          runId,
          trialId,
          env.jobId,
          epoch.value,
          EpochSecondCodec.epoch(env.now),
        ]
      )
    }
  }

  func seedClosedTrial(candidate: String, epoch: LearningEpoch) throws -> Int64 {
    let state = try state()
    return try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, close_reason, algorithm)
          VALUES (?, ?, ?, ?, 1, ?, ?, ?, 3, 0, ?, 'closed', 'fixture', ?)
          """,
        arguments: [
          env.jobId,
          epoch.value,
          state.stableDigest.rawValue,
          candidate,
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          LearningAlgorithm.v1.rawValue,
        ]
      )
      return db.lastInsertedRowID
    }
  }

  func seedLiveTrial(candidate: String, epoch: LearningEpoch) throws {
    let state = try state()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, ?, 1, ?, ?, ?, 3, 0, ?, 'open', ?)
          """,
        arguments: [
          env.jobId,
          epoch.value,
          state.stableDigest.rawValue,
          candidate,
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now),
          LearningAlgorithm.v1.rawValue,
        ]
      )
    }
  }

  func insertStartedOperation(
    _ db: Database,
    id: String,
    jobId: Int64,
    epoch: LearningEpoch
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO learning_operations(operation_id, job_id, learning_epoch, phase,
          source_digest, carrier_digest, route, provider_call_id, attempt_generation, state,
          reserved_tokens, reserved_cost_usd, reservation_state, created_at, key_digest)
        VALUES (?, ?, ?, 'evaluator', ?, 'carrier', 'route', 'call', 1, 'started',
          1, 0.1, 'open', ?, ?)
        """,
      arguments: [
        id,
        jobId,
        epoch.value,
        "source-\(id)",
        EpochSecondCodec.epoch(env.now),
        "key-\(id)",
      ]
    )
  }
}
