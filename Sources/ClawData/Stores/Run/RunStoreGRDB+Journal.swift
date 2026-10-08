import ClawCore
import Foundation
import GRDB

// MARK: - Journal Archive Input

extension RunStoreGRDB {
  public func journalExchangeInput(runID: Int64) throws(StoreError) -> JournalExchangeInput? {
    try database.readMapping { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT run.session_id, run.trigger_message_id, run.journal_admission, message.content
          FROM runs AS run JOIN messages AS message ON message.id = run.trigger_message_id
          WHERE run.id = ? AND run.origin = ?
          """,
        arguments: [runID, RunOrigin.interactive.rawValue]
      )
      guard let row, let encodedAdmission: Data = row["journal_admission"],
            let admission = try? JSONDecoder().decode(
              JournalExchangeAdmission.self,
              from: encodedAdmission
            )
      else {
        return nil
      }
      let sessionID: Int64 = row["session_id"]
      let triggerMessageID: Int64 = row["trigger_message_id"]
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
      let proposal: JournalExchangeInput.Proposal? = proposalRow.map { proposal in
        let proposalTriggerID: Int64 = proposal["proposal_source_id"]
        return JournalExchangeInput.Proposal(
          sourceID: "message:\(proposalTriggerID)",
          text: proposal["content"]
        )
      }
      return JournalExchangeInput(
        admission: admission,
        sessionID: sessionID,
        triggerMessageID: triggerMessageID,
        ownerText: row["content"],
        supportingProposal: proposal
      )
    }
  }
}

// MARK: - Journal Terminal Capture

extension RunStoreGRDB {
  static func captureJournalSource(_ db: Database, turn: AssistantTurn, now: Date) {
    guard let source = turn.journalSource else {
      return
    }
    JournalStoreGRDB.captureBestEffort(db, source: source, now: now) {
      let row = try Row.fetchOne(
        db,
        sql: "SELECT trigger_message_id, journal_admission FROM runs WHERE id = ?",
        arguments: [turn.runID]
      )
      guard let row, let encoded: Data = row["journal_admission"] else {
        return false
      }
      let admission = try JSONDecoder().decode(JournalExchangeAdmission.self, from: encoded)
      let triggerID: Int64 = row["trigger_message_id"]
      return source.id == "message:\(triggerID)" && source.sessionID == turn.sessionID
        && source.scope == admission.scope && source.occurredAt == admission.sourceTimestamp
        && source.day == admission.sourceDay && source.coderJobID == nil
    }
  }
}
