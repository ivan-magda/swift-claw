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
    #expect(Set([try #require(input.supportingProposal?.sourceID)]).isDisjoint(with: [source.id]))
    #expect(try fixture.sourceIDs().count == 2)
  }
}
