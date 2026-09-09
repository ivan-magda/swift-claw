import ClawCore
import Foundation
import GRDB

public struct ConferenceStoreGRDB: ConferenceStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func insertSubmission(
    id: UUID,
    prepared: PreparedConferenceSubmission,
    origin: ConferenceApprovedOrigin,
    now: Date
  ) throws(StoreError) -> ConferenceSubmissionInsert {
    try database.writeMapping { db in
      if let existing = try Self.fetch(
        db,
        participantUserID: origin.requesterUserID,
        caseID: prepared.caseSnapshot.id
      ) {
        return .existing(existing)
      }

      let caseJSON = try Self.encode(prepared.caseSnapshot)
      let originJSON = try Self.encode(origin)
      let timestamp = EpochSecondCodec.epoch(now)
      try db.execute(
        sql: """
          INSERT INTO conference_submissions(
            id, participant_user_id, case_id, case_json, answer, origin_json, state,
            created_ts, updated_ts
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          id.uuidString, origin.requesterUserID, prepared.caseSnapshot.id, caseJSON,
          prepared.answer, originJSON, ConferenceSubmissionState.queued.rawValue,
          timestamp, timestamp,
        ]
      )
      guard let inserted = try Self.fetch(db, id: id) else {
        throw StoreError.unexpected("Conference submission insert was not readable")
      }
      return .inserted(inserted)
    }
  }

  public func submission(id: UUID) throws(StoreError) -> ConferenceSubmission? {
    try database.readMapping { db in try Self.fetch(db, id: id) }
  }

  public func submission(
    participantUserID: Int64,
    caseID: String
  ) throws(StoreError) -> ConferenceSubmission? {
    try database.readMapping { db in
      try Self.fetch(db, participantUserID: participantUserID, caseID: caseID)
    }
  }

  public func claimNextQueued(now: Date) throws(StoreError) -> ConferenceSubmission? {
    try database.writeMapping { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT * FROM conference_submissions
          WHERE state = ?
          ORDER BY created_ts ASC, id ASC
          LIMIT 1
          """,
        arguments: [ConferenceSubmissionState.queued.rawValue]
      ) else {
        return nil
      }
      let id: String = row["id"]
      try db.execute(
        sql: """
          UPDATE conference_submissions
          SET state = ?, updated_ts = ?
          WHERE id = ? AND state = ?
          """,
        arguments: [
          ConferenceSubmissionState.running.rawValue, EpochSecondCodec.epoch(now), id,
          ConferenceSubmissionState.queued.rawValue,
        ]
      )
      guard db.changesCount == 1, let uuid = UUID(uuidString: id) else { return nil }
      return try Self.fetch(db, id: uuid)
    }
  }

  public func attachCoderJob(
    submissionID: UUID,
    coderJobID: UUID,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission? {
    try database.writeMapping { db in
      try db.execute(
        sql: """
          UPDATE conference_submissions
          SET coder_job_id = ?, updated_ts = ?
          WHERE id = ? AND state = ? AND (coder_job_id IS NULL OR coder_job_id = ?)
          """,
        arguments: [
          coderJobID.uuidString, EpochSecondCodec.epoch(now), submissionID.uuidString,
          ConferenceSubmissionState.running.rawValue, coderJobID.uuidString,
        ]
      )
      return try Self.fetch(db, id: submissionID)
    }
  }

  public func requeue(
    submissionID: UUID,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission? {
    try database.writeMapping { db in
      try db.execute(
        sql: """
          UPDATE conference_submissions
          SET state = ?, updated_ts = ?
          WHERE id = ? AND state = ? AND coder_job_id IS NULL
          """,
        arguments: [
          ConferenceSubmissionState.queued.rawValue, EpochSecondCodec.epoch(now),
          submissionID.uuidString, ConferenceSubmissionState.running.rawValue,
        ]
      )
      return try Self.fetch(db, id: submissionID)
    }
  }

  public func runningSubmissions() throws(StoreError) -> [ConferenceSubmission] {
    try database.readMapping { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM conference_submissions
          WHERE state = ?
          ORDER BY created_ts ASC, id ASC
          """,
        arguments: [ConferenceSubmissionState.running.rawValue]
      ).map(Self.decode)
    }
  }

  public func finish(
    submissionID: UUID,
    state: ConferenceSubmissionState,
    pullRequestURL: String?,
    branch: String?,
    commit: String?,
    failureReason: String?,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission? {
    try database.writeMapping { db in
      if let stored = try Self.fetch(db, id: submissionID), stored.state.isTerminal {
        return stored
      }
      guard state.isTerminal else {
        throw StoreError.unexpected("Conference finish requires a terminal state")
      }
      try db.execute(
        sql: """
          UPDATE conference_submissions
          SET state = ?, pull_request_url = ?, branch = ?, commit_sha = ?, failure_reason = ?,
              notification_enqueued = 0, updated_ts = ?
          WHERE id = ? AND state = ?
          """,
        arguments: [
          state.rawValue, pullRequestURL, branch, commit, failureReason,
          EpochSecondCodec.epoch(now), submissionID.uuidString,
          ConferenceSubmissionState.running.rawValue,
        ]
      )
      return try Self.fetch(db, id: submissionID)
    }
  }

  public func pendingNotifications() throws(StoreError) -> [ConferenceSubmission] {
    try database.readMapping { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM conference_submissions
          WHERE notification_enqueued = 0
            AND state NOT IN (?, ?)
          ORDER BY updated_ts ASC, id ASC
          """,
        arguments: [
          ConferenceSubmissionState.queued.rawValue,
          ConferenceSubmissionState.running.rawValue,
        ]
      ).map(Self.decode)
    }
  }

  public func markNotificationEnqueued(
    submissionID: UUID,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission? {
    try database.writeMapping { db in
      try db.execute(
        sql: """
          UPDATE conference_submissions
          SET notification_enqueued = 1, updated_ts = ?
          WHERE id = ? AND notification_enqueued = 0
            AND state NOT IN (?, ?)
          """,
        arguments: [
          EpochSecondCodec.epoch(now), submissionID.uuidString,
          ConferenceSubmissionState.queued.rawValue,
          ConferenceSubmissionState.running.rawValue,
        ]
      )
      return try Self.fetch(db, id: submissionID)
    }
  }
}

// MARK: - Record codec

private extension ConferenceStoreGRDB {
  static func fetch(_ db: Database, id: UUID) throws -> ConferenceSubmission? {
    try Row.fetchOne(
      db,
      sql: "SELECT * FROM conference_submissions WHERE id = ?",
      arguments: [id.uuidString]
    ).map(decode)
  }

  static func fetch(
    _ db: Database,
    participantUserID: Int64,
    caseID: String
  ) throws -> ConferenceSubmission? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT * FROM conference_submissions
        WHERE participant_user_id = ? AND case_id = ?
        """,
      arguments: [participantUserID, caseID]
    ).map(decode)
  }

  static func decode(_ row: Row) throws -> ConferenceSubmission {
    let idString: String = row["id"]
    let caseJSON: String = row["case_json"]
    let originJSON: String = row["origin_json"]
    let stateRaw: String = row["state"]
    let coderJobString: String? = row["coder_job_id"]
    let createdEpoch: Int64 = row["created_ts"]
    let updatedEpoch: Int64 = row["updated_ts"]

    guard let id = UUID(uuidString: idString),
      let state = ConferenceSubmissionState(rawValue: stateRaw),
      let createdAt = EpochSecondCodec.date(fromEpoch: createdEpoch),
      let updatedAt = EpochSecondCodec.date(fromEpoch: updatedEpoch)
    else {
      throw StoreError.unexpected("Invalid conference submission record")
    }
    let coderJobID: UUID?
    if let coderJobString {
      guard let parsed = UUID(uuidString: coderJobString) else {
        throw StoreError.unexpected("Invalid conference Coder job id")
      }
      coderJobID = parsed
    } else {
      coderJobID = nil
    }

    let notificationEnqueued: Bool = row["notification_enqueued"]
    return ConferenceSubmission(
      id: id,
      participantUserID: row["participant_user_id"],
      caseSnapshot: try decode(ConferenceCase.self, json: caseJSON),
      answer: row["answer"],
      origin: try decode(ConferenceApprovedOrigin.self, json: originJSON),
      state: state,
      coderJobID: coderJobID,
      pullRequestURL: row["pull_request_url"],
      branch: row["branch"],
      commit: row["commit_sha"],
      failureReason: row["failure_reason"],
      notificationEnqueued: notificationEnqueued,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  static func encode<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
      throw StoreError.unexpected("Conference JSON was not UTF-8")
    }
    return text
  }

  static func decode<Value: Decodable>(_ type: Value.Type, json: String) throws -> Value {
    do {
      return try JSONDecoder().decode(type, from: Data(json.utf8))
    } catch {
      throw StoreError.unexpected("Invalid conference JSON: \(error)")
    }
  }
}
