import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct PickUpPolicyVersionTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB
    let runID: Int64
  }

  private func fixture() throws -> Fixture {
    let queue = try TestDatabase.make()
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: 7),
        chatID: 7,
        userID: 7,
        text: "write the plan",
        isEdited: false,
        ts: Date()
      )
    )
    let runID = try #require(claim.runID)
    return Fixture(queue: queue, runs: RunStoreGRDB(writer: queue), runID: runID)
  }

  private func persistedPolicyVersion(_ queue: DatabaseQueue, runID: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT policy_version FROM runs WHERE id = ?",
        arguments: [runID]
      )
    }
  }

  private func runState(_ queue: DatabaseQueue, runID: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runID])
    }
  }

  @Test
  func pickUpStampsPolicyVersionInTheSameFlipToRunning() throws {
    // given
    let env = try fixture()

    // when
    let origin = try env.runs.pickUp(
      runID: env.runID,
      policyVersion: "abc0123456789def",
      now: Date()
    )

    // then — the RUNNING flip and the stamp are one UPDATE (§3.2)
    #expect(origin == .interactive)
    #expect(try runState(env.queue, runID: env.runID) == RunState.running.rawValue)
    #expect(try persistedPolicyVersion(env.queue, runID: env.runID) == "abc0123456789def")
  }

  @Test
  func theResumeConvenienceNeverStampsAPolicyVersion() throws {
    // given — the two-arg convenience models the resume path (which never re-stamps, preamble §3.2)
    let env = try fixture()

    // when
    _ = try #require(try env.runs.pickUp(runID: env.runID, now: Date()))

    // then
    #expect(try runState(env.queue, runID: env.runID) == RunState.running.rawValue)
    #expect(try persistedPolicyVersion(env.queue, runID: env.runID) == nil)
  }
}
