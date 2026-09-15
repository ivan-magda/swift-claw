import ClawCore
import GRDB

extension RunStoreGRDB {
  public func executionContext(runID: Int64, fallbackChatID: Int64) throws(StoreError)
    -> RunExecutionContext?
  {
    try database.readMapping { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
          SELECT runs.session_id, runs.origin, runs.requester_user_id, sessions.session_key
          FROM runs JOIN sessions ON sessions.id = runs.session_id WHERE runs.id = ?
          """,
          arguments: [runID]
        )
      else {
        return nil
      }
      guard let origin = RunOrigin(rawValue: row["origin"]) else {
        throw StoreError.unexpected("runs row \(runID) has an unrecognized origin")
      }
      let sessionKey: String = row["session_key"]
      let mode = SessionKey.mode(from: sessionKey)
      let storedChatID = SessionKey.chatID(from: sessionKey)
      if mode == .group {
        guard
          let storedChatID,
          SessionKey.telegramTopic(
            chatID: storedChatID,
            threadID: SessionKey.threadID(from: sessionKey)
          ) == sessionKey
        else {
          throw StoreError.unexpected("runs row \(runID) has an invalid group session key")
        }
      } else if origin == .interactive {
        guard let storedChatID, SessionKey.telegramDM(chatID: storedChatID) == sessionKey else {
          throw StoreError.unexpected("runs row \(runID) has an invalid interactive session key")
        }
      }
      let chatID = storedChatID ?? fallbackChatID
      let requesterUserID: Int64?
      if origin == .interactive {
        let persistedRequester: Int64? = row["requester_user_id"]
        let legacyRequester = mode == .direct ? SessionKey.chatID(from: sessionKey) : nil
        requesterUserID = persistedRequester ?? legacyRequester
      } else {
        requesterUserID = nil
      }
      return RunExecutionContext(
        sessionID: row["session_id"],
        origin: origin,
        requesterUserID: requesterUserID,
        mode: mode,
        deliveryTarget: try OutboxInsertion.outboxTarget(db, runID: runID, chatID: chatID)
      )
    }
  }
}
