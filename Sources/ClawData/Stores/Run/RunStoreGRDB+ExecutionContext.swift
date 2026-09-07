import ClawCore
import GRDB

extension RunStoreGRDB {
  public func executionContext(
    runId: Int64,
    fallbackChatId: Int64
  ) throws(StoreError) -> RunExecutionContext? {
    try database.readMapping { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT runs.session_id, runs.origin, runs.requester_user_id, sessions.session_key
            FROM runs JOIN sessions ON sessions.id = runs.session_id WHERE runs.id = ?
            """,
          arguments: [runId]
        )
      else {
        return nil
      }
      guard let origin = RunOrigin(rawValue: row["origin"]) else {
        throw StoreError.unexpected("runs row \(runId) has an unrecognized origin")
      }
      let sessionKey: String = row["session_key"]
      let mode = SessionKey.mode(from: sessionKey)
      let storedChatId = SessionKey.chatId(from: sessionKey)
      if mode == .group {
        guard let storedChatId,
          SessionKey.telegramTopic(
            chatId: storedChatId,
            threadId: SessionKey.threadId(from: sessionKey)
          ) == sessionKey
        else {
          throw StoreError.unexpected("runs row \(runId) has an invalid group session key")
        }
      } else if origin == .interactive {
        guard let storedChatId, SessionKey.telegramDM(chatId: storedChatId) == sessionKey else {
          throw StoreError.unexpected("runs row \(runId) has an invalid interactive session key")
        }
      }
      let chatId = storedChatId ?? fallbackChatId
      let requesterUserId: Int64?
      if origin == .interactive {
        let persistedRequester: Int64? = row["requester_user_id"]
        let legacyRequester = mode == .direct ? SessionKey.chatId(from: sessionKey) : nil
        requesterUserId = persistedRequester ?? legacyRequester
      } else {
        requesterUserId = nil
      }
      return RunExecutionContext(
        sessionId: row["session_id"],
        origin: origin,
        requesterUserId: requesterUserId,
        mode: mode,
        deliveryTarget: try OutboxInsertion.outboxTarget(db, runId: runId, chatId: chatId)
      )
    }
  }
}
