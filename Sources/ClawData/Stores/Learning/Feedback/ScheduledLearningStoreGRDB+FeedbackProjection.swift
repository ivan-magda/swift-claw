import ClawCore
import Foundation
import GRDB

// MARK: - Strict Feedback Projection

extension ScheduledLearningStoreGRDB {
  struct StoredFeedbackProjection {
    let event: FeedbackEvent
    let source: CandidateFeedbackSource
  }

  static func storedFeedback(
    _ db: Database,
    jobId: Int64,
    epoch: LearningEpoch,
    runIds: Set<Int64>,
    evaluationRuns: [String: Int64],
    cutoff: FeedbackRevision? = nil
  ) throws -> [StoredFeedbackProjection] {
    let runSubjects = runIds.map(String.init).sorted()
    let evaluationSubjects = evaluationRuns.keys.sorted()
    guard runSubjects.isEmpty == false || evaluationSubjects.isEmpty == false else {
      return []
    }

    var subjectPredicates: [String] = []
    var arguments: [any DatabaseValueConvertible] = [jobId, epoch.value]
    if runSubjects.isEmpty == false {
      let placeholders = Array(repeating: "?", count: runSubjects.count).joined(separator: ", ")
      subjectPredicates.append("(subject_kind = ? AND subject_digest IN (\(placeholders)))")
      arguments.append(FeedbackSubjectKind.run.rawValue)
      arguments.append(contentsOf: runSubjects)
    }
    if evaluationSubjects.isEmpty == false {
      let placeholders = Array(repeating: "?", count: evaluationSubjects.count)
        .joined(separator: ", ")
      subjectPredicates.append("(subject_kind = ? AND subject_digest IN (\(placeholders)))")
      arguments.append(FeedbackSubjectKind.evaluation.rawValue)
      arguments.append(contentsOf: evaluationSubjects)
    }
    let cutoffPredicate: String
    if let cutoff {
      cutoffPredicate = "AND feedback_revision <= ?"
      arguments.append(cutoff.value)
    } else {
      cutoffPredicate = ""
    }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT event_id, subject_kind, subject_digest, signal, payload, feedback_revision,
          supersedes, occurred_at, actor, transport_update_id
        FROM feedback_events
        WHERE job_id = ? AND learning_epoch = ?
          AND (\(subjectPredicates.joined(separator: " OR ")))
          \(cutoffPredicate)
        ORDER BY feedback_revision, event_id
        """,
      arguments: StatementArguments(arguments)
    )
    return try rows.map { row in
      try decodeStoredFeedback(
        row,
        jobId: jobId,
        epoch: epoch,
        runIds: runIds,
        evaluationRuns: evaluationRuns
      )
    }
  }

  private static func decodeStoredFeedback(
    _ row: Row,
    jobId: Int64,
    epoch: LearningEpoch,
    runIds: Set<Int64>,
    evaluationRuns: [String: Int64]
  ) throws -> StoredFeedbackProjection {
    guard
      let eventId = SQLiteStoredValue.int64(in: row, column: "event_id"),
      eventId > 0,
      let kindRaw = SQLiteStoredValue.string(in: row, column: "subject_kind"),
      let kind = FeedbackSubjectKind(rawValue: kindRaw),
      let subject = SQLiteStoredValue.string(in: row, column: "subject_digest"),
      let signalRaw = SQLiteStoredValue.string(in: row, column: "signal"),
      let signal = OwnerSignal(rawValue: signalRaw),
      signal.feedbackSubjectKind == kind,
      let payload = SQLiteStoredValue.nullableString(in: row, column: "payload"),
      let revisionRaw = SQLiteStoredValue.int64(in: row, column: "feedback_revision"),
      revisionRaw > 0,
      let supersedes = SQLiteStoredValue.nullableInt64(in: row, column: "supersedes"),
      let occurredRaw = SQLiteStoredValue.int64(in: row, column: "occurred_at"),
      let occurredAt = EpochSecondCodec.date(fromEpoch: occurredRaw),
      let actorRaw = SQLiteStoredValue.string(in: row, column: "actor"),
      let actor = AuditActor(rawValue: actorRaw),
      let updateId = SQLiteStoredValue.nullableInt64(in: row, column: "transport_update_id")
    else {
      throw StoreError.unexpected("assignment source holds an unreadable feedback event")
    }
    let runId: Int64
    switch kind {
    case .run:
      guard
        let parsed = Int64(subject),
        String(parsed) == subject,
        runIds.contains(parsed)
      else {
        throw StoreError.unexpected("run feedback subject does not match its assignment")
      }
      runId = parsed
    case .evaluation:
      guard let parsed = evaluationRuns[subject] else {
        throw StoreError.unexpected("evaluation feedback subject does not match its assignment")
      }
      runId = parsed
    case .candidate, .promotion:
      throw StoreError.unexpected("assignment feedback has an unsupported subject")
    }
    let revision = FeedbackRevision(revisionRaw)
    let event = FeedbackEvent(
      id: eventId,
      runId: runId,
      signal: signal,
      payload: payload.value,
      revision: revision,
      supersedes: supersedes.value,
      occurredAt: occurredAt,
      actor: actor,
      transportUpdateId: updateId.value
    )
    let digest = try FeedbackEventDigest.of(
      eventId: eventId,
      jobId: jobId,
      epoch: epoch,
      subjectKind: kind,
      subjectDigest: subject,
      signal: signal,
      payload: payload.value,
      actor: actor,
      transportUpdateId: updateId.value,
      revision: revision,
      supersedes: supersedes.value,
      occurredAtEpochSecond: occurredRaw
    )
    return StoredFeedbackProjection(
      event: event,
      source: CandidateFeedbackSource(
        eventId: eventId,
        digest: digest,
        revision: revision,
        subjectKind: kind,
        subjectDigest: subject,
        signal: signal
      )
    )
  }
}
