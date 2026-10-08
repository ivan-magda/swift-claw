import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct JournalNewCommandTests {
  @Test
  func proposalSurvivesResetAsSupportOnly() throws {
    // given
    let fixture = try JournalExchangeFixture()
    let first = try fixture.admit(updateID: 1, text: "Which database?")
    let runID = try #require(first.runID)
    _ = try fixture.runs.pickUp(runID: runID, now: fixture.now)
    let original = try #require(try fixture.runs.journalExchangeInput(runID: runID))
    let proposal = try fixture.source(input: original, reply: "Choose PostgreSQL for transactions.")
    _ = try fixture.runs.commitAssistantTurn(
      fixture.turn(input: original, runID: runID, source: proposal),
      now: fixture.now
    )
    _ = try fixture.commands.applyNew(
      updateID: 2,
      sessionKey: fixture.sessionKey,
      journalScope: fixture.scope,
      now: fixture.now
    )
    let confirmation = try fixture.admit(updateID: 3, text: "yes, choose it")
    let confirmationRunID = try #require(confirmation.runID)
    _ = try fixture.runs.pickUp(runID: confirmationRunID, now: fixture.now)
    let input = try #require(try fixture.runs.journalExchangeInput(runID: confirmationRunID))

    // when
    let source = try fixture.source(input: input, reply: "Selected PostgreSQL.")
    _ = try fixture.runs.commitAssistantTurn(
      fixture.turn(input: input, runID: confirmationRunID, source: source),
      now: fixture.now
    )
    _ = try fixture.commands.applyNew(
      updateID: 2,
      sessionKey: fixture.sessionKey,
      journalScope: fixture.scope,
      now: fixture.now
    )

    // then
    #expect(input.supportingProposal?.text == proposal.assistantText)
    #expect(input.supportingProposal?.sourceID == proposal.id)
    let dueIDs = try fixture.queue.read { db in
      try String.fetchAll(db, sql: "SELECT source_id FROM journal_sources WHERE due = 1")
    }
    #expect(dueIDs == [proposal.id])
    #expect(try fixture.sourceIDs().count == 2)
  }

  @Test
  func journalMarkFailurePreservesReset() throws {
    // given
    let fixture = try JournalExchangeFixture()
    let completed = try fixture.admit(updateID: 1, text: "old conversation")
    let completedRunID = try #require(completed.runID)
    _ = try fixture.runs.pickUp(runID: completedRunID, now: fixture.now)
    let input = try #require(try fixture.runs.journalExchangeInput(runID: completedRunID))
    let source = try fixture.source(input: input, reply: "old answer")
    _ = try fixture.runs.commitAssistantTurn(
      fixture.turn(input: input, runID: completedRunID, source: source),
      now: fixture.now
    )
    let pending = try fixture.admit(updateID: 2, text: "pending task")
    let pendingRunID = try #require(pending.runID)
    try fixture.queue.write { db in
      try RunStoreGRDB.setSessionTainted(db, sessionID: input.sessionID, now: fixture.now)
      try RunStoreGRDB.setSessionPrivateData(db, sessionID: input.sessionID, now: fixture.now)
      try db.execute(
        sql: """
          CREATE TEMP TRIGGER reject_journal_due BEFORE UPDATE OF due ON journal_sources
          BEGIN SELECT RAISE(ABORT, 'private fixture detail'); END
          """
      )
    }

    // when
    let result = try fixture.commands.applyNew(
      updateID: 3,
      sessionKey: fixture.sessionKey,
      journalScope: fixture.scope,
      now: fixture.now
    )

    // then
    #expect(result.newlyClaimed)
    #expect(result.sessionID == input.sessionID)
    #expect(result.supersededRunIDs == [pendingRunID])
    #expect(try fixture.state(runID: pendingRunID) == RunState.superseded.rawValue)
    let snapshot = try fixture.sessions.loadContextSnapshot(
      sessionID: input.sessionID,
      throughMessageID: Int64.max,
      limit: 10
    )
    #expect(snapshot.history.isEmpty)
    #expect(!snapshot.isTainted)
    #expect(!snapshot.hasPrivateData)
    let status = try JournalStoreGRDB(writer: fixture.queue).status(
      ownerUserID: fixture.scope.ownerUserID,
      now: fixture.now
    )
    #expect(status.lastRedactedError == "Journal reset marking failed")
    #expect(status.pendingCount == 1)
    let replay = try fixture.commands.applyNew(
      updateID: 3,
      sessionKey: fixture.sessionKey,
      journalScope: fixture.scope,
      now: fixture.now
    )
    #expect(!replay.newlyClaimed)
    #expect(
      try JournalStoreGRDB(writer: fixture.queue).status(
        ownerUserID: fixture.scope.ownerUserID,
        now: fixture.now
      ) == status
    )
  }

}
