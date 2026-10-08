import ClawCore
import Foundation
import GRDB

// MARK: - Journal Archive Input

extension RunStoreGRDB {
  public func journalExchangeInput(runID: Int64) throws(StoreError) -> JournalExchangeInput? {
    try database.readMapping { db in
      let runRow = try Row.fetchOne(
        db,
        sql: """
          SELECT run.session_id, run.trigger_message_id, run.journal_admission, message.content
          FROM runs AS run JOIN messages AS message ON message.id = run.trigger_message_id
          WHERE run.id = ? AND run.origin = ?
          """,
        arguments: [runID, RunOrigin.interactive.rawValue]
      )
      guard let runRow, let encodedAdmission: Data = runRow["journal_admission"] else {
        return nil
      }
      let admission = try? JSONDecoder().decode(
        JournalExchangeAdmission.self,
        from: encodedAdmission
      )
      guard let admission else {
        return nil
      }

      let sessionID: Int64 = runRow["session_id"]
      let triggerMessageID: Int64 = runRow["trigger_message_id"]
      let proposalRow = try Row.fetchOne(
        db,
        sql: """
          SELECT message.content,
            COALESCE(run.trigger_message_id, message.id) AS proposal_source_id
          FROM messages AS message
          JOIN runs AS run ON run.id = message.run_id
          WHERE message.session_id = ? AND message.id < ? AND message.role = ?
            AND message.tool_calls IS NULL AND run.state = ?
          ORDER BY message.id DESC LIMIT 1
          """,
        arguments: [
          sessionID,
          triggerMessageID,
          MessageRole.assistant.rawValue,
          RunState.done.rawValue,
        ]
      )
      let supportingProposal: JournalExchangeInput.Proposal? = proposalRow.map { proposalRow in
        let proposalSourceID: Int64 = proposalRow["proposal_source_id"]
        return JournalExchangeInput.Proposal(
          sourceID: "message:\(proposalSourceID)",
          text: proposalRow["content"]
        )
      }

      return JournalExchangeInput(
        admission: admission,
        sessionID: sessionID,
        triggerMessageID: triggerMessageID,
        ownerText: runRow["content"],
        supportingProposal: supportingProposal
      )
    }
  }
}

// MARK: - Journal Terminal Capture

extension RunStoreGRDB {
  static func commitJournalCapture(_ db: Database, turn: AssistantTurn, now: Date) {
    guard let capture = turn.journalCapture else {
      return
    }

    JournalStoreGRDB.captureBestEffort(db, capture: capture, now: now) {
      let runRow = try Row.fetchOne(
        db,
        sql: "SELECT trigger_message_id, journal_admission FROM runs WHERE id = ?",
        arguments: [turn.runID]
      )
      guard let runRow, let encodedAdmission: Data = runRow["journal_admission"] else {
        return false
      }
      let admission = try JSONDecoder().decode(
        JournalExchangeAdmission.self,
        from: encodedAdmission
      )
      guard capture.scope == admission.scope else {
        return false
      }
      guard case .source(let source) = capture else {
        return true
      }

      let triggerMessageID: Int64 = runRow["trigger_message_id"]
      return source.id == "message:\(triggerMessageID)" && source.sessionID == turn.sessionID
        && source.scope == admission.scope && source.occurredAt == admission.sourceTimestamp
        && source.day == admission.sourceDay && source.coderJobID == nil
    }
  }
}
