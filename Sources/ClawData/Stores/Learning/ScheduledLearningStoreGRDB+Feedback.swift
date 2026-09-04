import ClawCore
import Foundation
import GRDB

extension ScheduledLearningStoreGRDB {
  public func createTargets(
    _ targets: [NewFeedbackTarget],
    chunks: [LearningNoticeChunk]
  ) throws(StoreError) -> [FeedbackTarget] {
    try database.writeMapping { db in
      let createdAt = Date()
      for chunk in chunks {
        _ = try OutboxStoreGRDB.insertNotice(db, chunk: chunk, now: createdAt)
      }
      for target in targets {
        try Self.insertTarget(db, target)
      }
      return try targets.map { target in
        guard let stored = try Self.readTarget(db, nonce: target.nonce) else {
          throw StoreError.unexpected("feedback target was not readable after insert")
        }
        return stored
      }
    }
  }

  public func feedbackTarget(nonce: String) throws(StoreError) -> FeedbackTarget? {
    try database.readMapping { db in
      try Self.readTarget(db, nonce: nonce)
    }
  }

  public func consumeAndAppendEvent(_ tap: FeedbackTap) throws(StoreError) -> FeedbackOutcome {
    try database.writeMapping { db in
      guard tap.signal.requiresPayloadChallenge == false else {
        let target = try Self.readTarget(db, nonce: tap.nonce)
        let outcome = FeedbackOutcome.requiresPayloadChallenge
        try Self.auditFeedback(db, tap: tap, target: target, outcome: outcome)
        return outcome
      }

      guard let target = try Self.consumeTarget(db, tap: tap) else {
        let found = try Self.readTarget(db, nonce: tap.nonce)
        let outcome = try Self.failedOutcome(db, tap: tap, target: found)
        try Self.auditFeedback(db, tap: tap, target: found, outcome: outcome)
        return outcome
      }

      guard let revision = try Self.advanceFeedbackRevision(db, target: target) else {
        throw StoreError.unexpected("feedback revision CAS lost after target consumption")
      }
      let event = try Self.insertEvent(db, tap: tap, target: target, revision: revision)
      try Self.applyImmediateVeto(db, target: target, signal: tap.signal)
      let outcome = FeedbackOutcome.recorded(event)
      try Self.auditFeedback(db, tap: tap, target: target, outcome: outcome)
      return outcome
    }
  }

  public func feedbackEvents(
    jobId: Int64,
    epoch: LearningEpoch,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String
  ) throws(StoreError) -> [FeedbackEvent] {
    try database.readMapping { db in
      try Self.readEvents(
        db,
        jobId: jobId,
        epoch: epoch,
        subjectKind: subjectKind,
        subjectDigest: subjectDigest
      )
    }
  }
}

// MARK: - Target Rows

private extension ScheduledLearningStoreGRDB {
  static func insertTarget(_ db: Database, _ target: NewFeedbackTarget) throws {
    guard
      target.allowedActions.isEmpty == false,
      target.allowedActions.allSatisfy({ signal in
        signal.feedbackSubjectKind == target.subjectKind
      })
    else {
      throw StoreError.unexpected("feedback target actions do not match its subject kind")
    }
    let actions = try JSONEncoder().encode(target.allowedActions.map(\.rawValue))
    guard let encodedActions = String(data: actions, encoding: .utf8) else {
      throw StoreError.unexpected("feedback action encoding was not UTF-8")
    }
    try db.execute(
      sql: """
        INSERT INTO feedback_targets(nonce, job_id, learning_epoch, subject_kind, subject_digest,
          allowed_actions, owner_user_id, chat_id, expires_at, consumed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        """,
      arguments: [
        target.nonce,
        target.jobId,
        target.epoch.value,
        target.subjectKind.rawValue,
        target.subjectDigest,
        encodedActions,
        target.ownerUserId,
        target.chatId,
        EpochSecondCodec.epoch(target.expiresAt),
      ]
    )
  }

  static func readTarget(_ db: Database, nonce: String) throws -> FeedbackTarget? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM feedback_targets WHERE nonce = ?",
        arguments: [nonce]
      )
    else {
      return nil
    }
    return try decodeTarget(row)
  }

  static func decodeTarget(_ row: Row) throws -> FeedbackTarget {
    let rawActions: String = row["allowed_actions"]
    guard
      let subjectKind = FeedbackSubjectKind(rawValue: row["subject_kind"]),
      let actionData = rawActions.data(using: .utf8),
      let actionValues = try? JSONDecoder().decode([String].self, from: actionData),
      !actionValues.isEmpty,
      actionValues.allSatisfy({ OwnerSignal(rawValue: $0) != nil }),
      let expiresAt = EpochSecondCodec.date(fromEpoch: row["expires_at"])
    else {
      throw StoreError.unexpected("feedback target row is unreadable")
    }
    let consumedEpoch: Int64? = row["consumed_at"]
    let actions = actionValues.compactMap(OwnerSignal.init(rawValue:))
    return FeedbackTarget(
      targetId: row["target_id"],
      nonce: row["nonce"],
      jobId: row["job_id"],
      epoch: LearningEpoch(row["learning_epoch"]),
      subjectKind: subjectKind,
      subjectDigest: row["subject_digest"],
      allowedActions: actions,
      ownerUserId: row["owner_user_id"],
      chatId: row["chat_id"],
      expiresAt: expiresAt,
      consumedAt: consumedEpoch.flatMap(EpochSecondCodec.date(fromEpoch:))
    )
  }
}

// MARK: - Consumption CAS

private extension ScheduledLearningStoreGRDB {
  static func consumeTarget(_ db: Database, tap: FeedbackTap) throws -> FeedbackTarget? {
    let row = try Row.fetchOne(
      db,
      sql: """
        UPDATE feedback_targets SET consumed_at = ?
        WHERE nonce = ? AND consumed_at IS NULL AND owner_user_id = ? AND chat_id = ?
          AND expires_at > ?
          AND learning_epoch = (
            SELECT learning_epoch FROM job_learning_state
            WHERE job_id = feedback_targets.job_id
          )
          AND EXISTS (
            SELECT 1 FROM json_each(feedback_targets.allowed_actions) WHERE value = ?
          )
        RETURNING *
        """,
      arguments: [
        EpochSecondCodec.epoch(tap.occurredAt),
        tap.nonce,
        tap.ownerUserId,
        tap.chatId,
        EpochSecondCodec.epoch(tap.occurredAt),
        tap.signal.rawValue,
      ]
    )
    return try row.map(decodeTarget)
  }

  static func failedOutcome(
    _ db: Database,
    tap: FeedbackTap,
    target: FeedbackTarget?
  ) throws -> FeedbackOutcome {
    guard let target else {
      return .targetMissing
    }
    if target.consumedAt != nil {
      return .alreadyConsumed
    }
    if target.ownerUserId != tap.ownerUserId {
      return .ownerMismatch
    }
    if target.chatId != tap.chatId {
      return .chatMismatch
    }
    if target.expiresAt <= tap.occurredAt {
      return .expired
    }
    if target.allowedActions.contains(tap.signal) == false {
      return .actionMismatch
    }
    guard
      let currentEpoch = try Int.fetchOne(
        db,
        sql: "SELECT learning_epoch FROM job_learning_state WHERE job_id = ?",
        arguments: [target.jobId]
      )
    else {
      return .staleEpoch
    }
    if currentEpoch != target.epoch.value {
      return .staleEpoch
    }
    throw StoreError.unexpected("feedback target CAS lost without a classified predicate")
  }

  static func advanceFeedbackRevision(
    _ db: Database,
    target: FeedbackTarget
  ) throws -> FeedbackRevision? {
    let revision = try Int64.fetchOne(
      db,
      sql: """
        UPDATE job_learning_state SET feedback_revision = feedback_revision + 1
        WHERE job_id = ? AND learning_epoch = ?
        RETURNING feedback_revision
        """,
      arguments: [target.jobId, target.epoch.value]
    )
    return revision.map { value in
      FeedbackRevision(value)
    }
  }
}

// MARK: - Event Rows

private extension ScheduledLearningStoreGRDB {
  static func insertEvent(
    _ db: Database,
    tap: FeedbackTap,
    target: FeedbackTarget,
    revision: FeedbackRevision
  ) throws -> FeedbackEvent {
    let supersedes = try Int64.fetchOne(
      db,
      sql: """
        SELECT event_id FROM feedback_events
        WHERE job_id = ? AND learning_epoch = ? AND subject_kind = ? AND subject_digest = ?
        ORDER BY feedback_revision DESC, event_id DESC LIMIT 1
        """,
      arguments: [
        target.jobId, target.epoch.value, target.subjectKind.rawValue, target.subjectDigest,
      ]
    )
    try db.execute(
      sql: """
        INSERT INTO feedback_events(job_id, learning_epoch, subject_kind, subject_digest, signal,
          payload, actor, transport_update_id, feedback_revision, supersedes, occurred_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        target.jobId,
        target.epoch.value,
        target.subjectKind.rawValue,
        target.subjectDigest,
        tap.signal.rawValue,
        tap.payload,
        AuditActor.owner.rawValue,
        tap.transportUpdateId,
        revision.value,
        supersedes,
        EpochSecondCodec.epoch(tap.occurredAt),
      ]
    )
    return FeedbackEvent(
      id: db.lastInsertedRowID,
      runId: try runId(db, target: target),
      signal: tap.signal,
      payload: tap.payload,
      revision: revision,
      supersedes: supersedes,
      occurredAt: tap.occurredAt,
      actor: .owner,
      transportUpdateId: tap.transportUpdateId
    )
  }

  static func readEvents(
    _ db: Database,
    jobId: Int64,
    epoch: LearningEpoch,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String
  ) throws -> [FeedbackEvent] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT event_id, signal, payload, actor, transport_update_id, feedback_revision,
          supersedes, occurred_at
        FROM feedback_events
        WHERE job_id = ? AND learning_epoch = ? AND subject_kind = ? AND subject_digest = ?
        ORDER BY feedback_revision, event_id
        """,
      arguments: [jobId, epoch.value, subjectKind.rawValue, subjectDigest]
    )
    return try rows.map { row in
      guard
        let signal = OwnerSignal(rawValue: row["signal"]),
        let actor = AuditActor(rawValue: row["actor"]),
        let occurredAt = EpochSecondCodec.date(fromEpoch: row["occurred_at"])
      else {
        throw StoreError.unexpected("feedback event row is unreadable")
      }
      return FeedbackEvent(
        id: row["event_id"],
        runId: try runId(
          db,
          jobId: jobId,
          subjectKind: subjectKind,
          subjectDigest: subjectDigest
        ),
        signal: signal,
        payload: row["payload"],
        revision: FeedbackRevision(row["feedback_revision"]),
        supersedes: row["supersedes"],
        occurredAt: occurredAt,
        actor: actor,
        transportUpdateId: row["transport_update_id"]
      )
    }
  }

  static func runId(_ db: Database, target: FeedbackTarget) throws -> Int64? {
    try runId(
      db,
      jobId: target.jobId,
      subjectKind: target.subjectKind,
      subjectDigest: target.subjectDigest
    )
  }

  static func runId(
    _ db: Database,
    jobId: Int64,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String
  ) throws -> Int64? {
    switch subjectKind {
    case .run:
      return Int64(subjectDigest)
    case .evaluation:
      return try Int64.fetchOne(
        db,
        sql: """
          SELECT run_id FROM learning_evaluations
          WHERE job_id = ? AND evaluation_digest = ?
          """,
        arguments: [jobId, subjectDigest]
      )
    case .candidate, .promotion:
      return nil
    }
  }
}

// MARK: - Exact Immediate Vetoes

private extension ScheduledLearningStoreGRDB {
  static func applyImmediateVeto(
    _ db: Database,
    target: FeedbackTarget,
    signal: OwnerSignal
  ) throws {
    let trialId: Int64?
    switch signal {
    case .candidateReject:
      trialId = try closeCandidateTrial(db, target: target)
    case .evaluationDispute:
      trialId = try closeEvaluationTrial(db, target: target)
    case .resultUseful, .resultNotUseful, .resultCorrection, .evaluationConfirm,
      .candidateApprove, .candidateEdit, .promotionRollback:
      trialId = nil
    }
    if let trialId {
      try db.execute(
        sql: """
          UPDATE job_learning_state SET open_trial_id = NULL
          WHERE job_id = ? AND learning_epoch = ? AND open_trial_id = ?
          """,
        arguments: [target.jobId, target.epoch.value, trialId]
      )
    }
  }

  static func closeCandidateTrial(_ db: Database, target: FeedbackTarget) throws -> Int64? {
    try Int64.fetchOne(
      db,
      sql: """
        UPDATE learning_trials SET state = ?, close_reason = ?
        WHERE trial_id = (
          SELECT trial.trial_id
          FROM learning_trials AS trial
          JOIN learning_candidates AS candidate
            ON candidate.candidate_digest = trial.candidate_digest
          JOIN lesson_sets AS replacement
            ON replacement.job_id = candidate.job_id
            AND replacement.digest = candidate.replacement_digest
          JOIN job_learning_state AS learning_state
            ON learning_state.job_id = trial.job_id
            AND learning_state.learning_epoch = trial.learning_epoch
            AND learning_state.stable_lesson_set_digest = trial.base_digest
            AND learning_state.open_trial_id = trial.trial_id
          WHERE trial.job_id = ? AND trial.learning_epoch = ?
            AND trial.state IN (?, ?)
            AND trial.candidate_digest = ?
            AND candidate.job_id = trial.job_id
            AND candidate.learning_epoch = trial.learning_epoch
            AND candidate.base_digest = trial.base_digest
            AND candidate.algorithm = trial.algorithm
          ORDER BY trial.trial_id DESC LIMIT 1
        )
        RETURNING trial_id
        """,
      arguments: [
        LearningTrialState.fellBack.rawValue,
        Self.hardVetoReason,
        target.jobId,
        target.epoch.value,
        LearningTrialState.open.rawValue,
        LearningTrialState.draining.rawValue,
        target.subjectDigest,
      ]
    )
  }

  static func closeEvaluationTrial(_ db: Database, target: FeedbackTarget) throws -> Int64? {
    try Int64.fetchOne(
      db,
      sql: """
        UPDATE learning_trials SET state = ?, close_reason = ?
        WHERE trial_id = (
          SELECT trial.trial_id
          FROM learning_trials AS trial
          JOIN learning_candidates AS candidate
            ON candidate.candidate_digest = trial.candidate_digest
          JOIN lesson_sets AS replacement
            ON replacement.job_id = candidate.job_id
            AND replacement.digest = candidate.replacement_digest
          JOIN trial_assignments AS assignment
            ON assignment.trial_id = trial.trial_id
          JOIN job_learning_state AS learning_state
            ON learning_state.job_id = trial.job_id
            AND learning_state.learning_epoch = trial.learning_epoch
            AND learning_state.stable_lesson_set_digest = trial.base_digest
            AND learning_state.open_trial_id = trial.trial_id
          WHERE trial.job_id = ? AND trial.learning_epoch = ?
            AND trial.state IN (?, ?)
            AND candidate.job_id = trial.job_id
            AND candidate.learning_epoch = trial.learning_epoch
            AND candidate.base_digest = trial.base_digest
            AND candidate.algorithm = trial.algorithm
            AND assignment.job_id = trial.job_id
            AND assignment.learning_epoch = trial.learning_epoch
            AND assignment.trial_generation = trial.generation
            AND assignment.evaluation_digest = ?
            AND assignment.evaluation_required = 1
          ORDER BY trial.trial_id DESC LIMIT 1
        )
        RETURNING trial_id
        """,
      arguments: [
        LearningTrialState.fellBack.rawValue,
        Self.hardVetoReason,
        target.jobId,
        target.epoch.value,
        LearningTrialState.open.rawValue,
        LearningTrialState.draining.rawValue,
        target.subjectDigest,
      ]
    )
  }
}

// MARK: - Audit

private extension ScheduledLearningStoreGRDB {
  static let hardVetoReason = "hard_veto"

  static func auditFeedback(
    _ db: Database,
    tap: FeedbackTap,
    target: FeedbackTarget?,
    outcome: FeedbackOutcome
  ) throws {
    let actor: AuditActor = target?.ownerUserId == tap.ownerUserId ? .owner : .system
    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: actor,
        action: .learningFeedback,
        tool: tap.signal.rawValue,
        argsRedacted: auditSubject(target),
        resultSize: tap.payload?.utf8.count ?? 0,
        decision: outcome.auditDecision,
        runId: try target.flatMap { value in
          try runId(db, target: value)
        },
        ts: tap.occurredAt
      )
    )
  }

  static func auditSubject(_ target: FeedbackTarget?) -> String {
    guard let target else {
      return ""
    }
    return "subject_kind=\(target.subjectKind.rawValue),subject_digest=\(target.subjectDigest)"
  }
}

private extension FeedbackOutcome {
  var auditDecision: String {
    switch self {
    case .recorded: "recorded"
    case .targetMissing: "unknown"
    case .ownerMismatch: "owner_mismatch"
    case .chatMismatch: "chat_mismatch"
    case .expired: "expired"
    case .actionMismatch: "action_mismatch"
    case .staleEpoch: "stale_epoch"
    case .alreadyConsumed: "consumed"
    case .requiresPayloadChallenge: "challenge_required"
    }
  }
}

private extension OwnerSignal {
  var requiresPayloadChallenge: Bool {
    switch self {
    case .resultCorrection, .candidateEdit:
      true
    case .resultUseful, .resultNotUseful, .evaluationConfirm, .evaluationDispute,
      .candidateApprove, .candidateReject, .promotionRollback:
      false
    }
  }
}
