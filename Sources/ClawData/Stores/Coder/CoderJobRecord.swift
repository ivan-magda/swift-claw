import ClawCore
import Foundation
import GRDB

enum CoderJobRecord {
  static func fetch(_ db: Database, id: UUID) throws -> CoderJob? {
    try Row.fetchOne(
      db,
      sql: "SELECT * FROM coder_jobs WHERE id = ?",
      arguments: [id.uuidString]
    ).map(decode)
  }

  static func decode(_ row: Row) throws -> CoderJob {
    guard let id = UUID(uuidString: row["id"]),
      let state = CoderJobState(rawValue: row["state"]),
      let ownership = CoderProcessOwnership(rawValue: row["process_ownership"]),
      let createdAt = EpochSecondCodec.date(fromEpoch: row["created_ts"])
    else {
      throw StoreError.unexpected("Invalid Coder job record")
    }
    let prepared: CoderPreparedRequest = try decodeJSON(row["prepared_json"])
    let receipt: CoderProcessReceipt? = try (row["process_receipt_json"] as String?).map(decodeJSON)
    let result: CoderResult? = try (row["result_json"] as String?).map(decodeJSON)
    return CoderJob(
      id: id,
      origin: CoderOrigin(
        runID: row["origin_run_id"],
        sessionID: row["origin_session_id"],
        requesterUserID: row["requester_user_id"],
        chatID: row["chat_id"],
        toolCallID: row["tool_call_id"],
        approvalID: row["approval_id"]
      ),
      prepared: prepared,
      state: state,
      createdAt: createdAt,
      slotReserved: row["slot_reserved"],
      ownership: ownership,
      processReceipt: receipt,
      result: result
    )
  }

  static func insert(
    _ db: Database,
    id: UUID,
    prepared: CoderPreparedRequest,
    origin: CoderOrigin,
    now: Date
  ) throws -> CoderJob {
    try db.execute(
      sql: """
        INSERT INTO coder_jobs(id, origin_run_id, origin_session_id, requester_user_id, chat_id,
          tool_call_id, approval_id, prepared_json, state, slot_reserved, checkout_path,
          common_git_directory, process_ownership, created_ts, updated_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?)
        """,
      arguments: [
        id.uuidString, origin.runID, origin.sessionID, origin.requesterUserID, origin.chatID,
        origin.toolCallID, origin.approvalID, try encodeJSON(prepared),
        CoderJobState.admitted.rawValue, prepared.checkoutPath, prepared.commonGitDirectory,
        CoderProcessOwnership.none.rawValue, EpochSecondCodec.epoch(now),
        EpochSecondCodec.epoch(now),
      ]
    )
    guard let job = try fetch(db, id: id) else {
      throw StoreError.unexpected("Coder admission returned no row")
    }
    return job
  }

  static func encodeJSON(_ value: some Encodable) throws -> String {
    guard let json = CanonicalJSON.encode(value) else {
      throw StoreError.unexpected("Unencodable Coder record")
    }
    return json
  }
}

// MARK: - Decoding

private extension CoderJobRecord {
  static func decodeJSON<Value: Decodable>(_ json: String) throws -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    } catch {
      throw StoreError.unexpected("Undecodable Coder record")
    }
  }
}
