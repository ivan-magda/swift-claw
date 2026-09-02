import ClawAgent
import ClawCore
import ClawData
import Foundation
import GRDB
import Testing

@testable import ClawGateway

/// The lane closure is the only in-process owner of a deferred settlement. Boot reconciliation is
/// the crash backstop: a cancelled bound run whose settlement waited for the next daemon start
/// would fall out of the learning loop for as long as the daemon stays up.
@Suite struct LaneSettlementTests {
  @Test func theLaneTailSettlesACancelledRunWithoutWaitingForBoot() async throws {
    // given — a bound run enqueued on its session lane, cancelled while the turn is in flight
    let env = try LaneSettlementEnvironment.make()
    let runId = try env.boundRun()
    let enqueuer = env.enqueuer(dispatcher: env.cancellingDispatcher())

    // when — the lane closure unwinds
    await enqueuer.enqueue(
      runId: runId,
      sessionId: env.sessionId,
      chatId: 777,
      triggerMessageId: try env.triggerMessageId(runId: runId)
    )
    let drained = await env.lanes.drain(timeout: .seconds(5), clock: ContinuousClock())

    // then — settlement happened in-process, not at the next boot
    #expect(drained == .drained)
    let receipt = try #require(try env.learning.settlement(runId: runId))
    #expect(receipt.terminalCause == .ownerCancelled)
    #expect(receipt.settledAt != nil)
  }

  @Test func theLaneTailStillSettlesWhenTheTurnThrows() async throws {
    // given — the same cancellation, but the turn leaves through the `catch` arm
    let env = try LaneSettlementEnvironment.make()
    let runId = try env.boundRun()
    let dispatcher = env.cancellingDispatcher(error: StoreError.diskFull)
    let enqueuer = env.enqueuer(dispatcher: dispatcher)

    // when
    await enqueuer.enqueue(
      runId: runId,
      sessionId: env.sessionId,
      chatId: 777,
      triggerMessageId: try env.triggerMessageId(runId: runId)
    )
    _ = await env.lanes.drain(timeout: .seconds(5), clock: ContinuousClock())

    // then — every exit from the turn passes the tail, not just the happy one
    #expect(try env.learning.settlement(runId: runId)?.settledAt != nil)
  }
}

// MARK: - Environment

/// One armed scheduled job over a real in-memory database, plus the lane registry the enqueuer
/// admits onto. The dispatcher double stands in for the provider round-trip only — the run store
/// and the learning store are the real ones, because the settlement boundary is SQL.
private struct LaneSettlementEnvironment {
  let queue: DatabaseQueue
  let jobs: ScheduledJobStoreGRDB
  let runs: RunStoreGRDB
  let learning: ScheduledLearningStoreGRDB
  let lanes: SessionLaneRegistry
  let jobId: Int64
  let sessionId: Int64
  let now: Date

  static func make() throws -> LaneSettlementEnvironment {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let now = Date(timeIntervalSince1970: 1_782_000_600)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatId: 777,
        label: "digest",
        prompt: "Summarize my unread items",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
    guard case .fired(let fired) = try jobs.fireNow(jobId: job.id, now: now) else {
      throw StoreError.unexpected("job \(job.id) refused to fire")
    }
    let runs = RunStoreGRDB(writer: queue)
    // The fixture's first fire only establishes the job's session; the run it created is retired
    // so the overlap guard lets each test fire its own.
    try runs.failRun(runId: fired.runId, cause: .unknown, now: now)
    return LaneSettlementEnvironment(
      queue: queue,
      jobs: jobs,
      runs: runs,
      learning: ScheduledLearningStoreGRDB(writer: queue),
      lanes: SessionLaneRegistry(),
      jobId: job.id,
      sessionId: fired.sessionId,
      now: now
    )
  }

  func boundRun() throws -> Int64 {
    guard case .fired(let fired) = try jobs.fireNow(jobId: jobId, now: now) else {
      throw StoreError.unexpected("job \(jobId) refused to fire")
    }
    _ = try runs.pickUp(runId: fired.runId, now: now)
    return fired.runId
  }

  func triggerMessageId(runId: Int64) throws -> Int64 {
    try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT trigger_message_id FROM runs WHERE id = ?",
        arguments: [runId]
      ) ?? 0
    }
  }

  func enqueuer(dispatcher: any TurnDispatching) -> TurnEnqueuer {
    TurnEnqueuer(
      lanes: lanes,
      turns: dispatcher,
      learning: learning,
      now: { now },
      logger: TestLog.silent
    )
  }

  func cancellingDispatcher(error: (any Error)? = nil) -> CancellingDispatcher {
    CancellingDispatcher(runs: runs, sessionId: sessionId, now: now, error: error)
  }
}

/// Terminates the run the way `/stop` does while the turn is still in flight, then returns or
/// throws — the exact shape whose lane tail must still settle.
private struct CancellingDispatcher: TurnDispatching {
  let runs: RunStoreGRDB
  let sessionId: Int64
  let now: Date
  let error: (any Error)?

  func run(runId: Int64, sessionId: Int64, chatId: Int64, triggerMessageId: Int64) async throws {
    _ = try runs.cancelActiveRun(sessionId: self.sessionId, reason: .cancelled, now: now)
    if let error {
      throw error
    }
  }
}
