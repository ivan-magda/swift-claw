import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct PickUpPolicyVersionTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB
    let runId: Int64
  }

  private func fixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 7),
        chatId: 7,
        userId: 7,
        text: "write the plan",
        isEdited: false,
        ts: Date()
      )
    )
    let runId = try #require(claim.runId)
    return Fixture(queue: queue, runs: RunStoreGRDB(writer: queue), runId: runId)
  }

  private func persistedPolicyVersion(_ queue: DatabaseQueue, runId: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT policy_version FROM runs WHERE id = ?",
        arguments: [runId]
      )
    }
  }

  private func runState(_ queue: DatabaseQueue, runId: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
    }
  }

  @Test func pickUpStampsPolicyVersionInTheSameFlipToRunning() throws {
    // given
    let env = try fixture()

    // when
    let origin = try env.runs.pickUp(
      runId: env.runId,
      policyVersion: "abc0123456789def",
      now: Date()
    )

    // then — the RUNNING flip and the stamp are one UPDATE (§3.2)
    #expect(origin == .interactive)
    #expect(try runState(env.queue, runId: env.runId) == RunState.running.rawValue)
    #expect(try persistedPolicyVersion(env.queue, runId: env.runId) == "abc0123456789def")
  }

  @Test func theResumeConvenienceNeverStampsAPolicyVersion() throws {
    // given — the two-arg convenience models the resume path (which never re-stamps, preamble §3.2)
    let env = try fixture()

    // when
    _ = try #require(try env.runs.pickUp(runId: env.runId, now: Date()))

    // then
    #expect(try runState(env.queue, runId: env.runId) == RunState.running.rawValue)
    #expect(try persistedPolicyVersion(env.queue, runId: env.runId) == nil)
  }
}
