import ClawAgent
import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData
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

  @Test func theLaneTailNotifiesTheSealerAndDoesNotOnlySettle() async throws {
    // given — the same cancelled bound run; nothing but the tail's own notification can put it in
    // front of the sealer before the next periodic sweep
    let env = try LaneSettlementEnvironment.make()
    let runId = try env.boundRun()
    let enqueuer = env.enqueuer(dispatcher: env.cancellingDispatcher())

    // when
    await enqueuer.enqueue(
      runId: runId,
      sessionId: env.sessionId,
      chatId: 777,
      triggerMessageId: try env.triggerMessageId(runId: runId)
    )
    _ = await env.lanes.drain(timeout: .seconds(5), clock: ContinuousClock())

    // then — a settlement with no notification would leave this receipt unwritten until a sweep
    try await waitUntilSealed(runId: runId, in: env)
    #expect(try env.learning.evidence(runId: runId) != nil)
  }

  @Test func theBootReparkedApprovalLaneCarriesTheSameTail() async throws {
    // given — a bound run parked on an unexpired approval, re-parked by boot onto its session lane;
    // `ApprovalBootReconciler` enqueues onto the registry itself rather than through `TurnEnqueuer`
    let env = try LaneSettlementEnvironment.make()
    let parked = try env.parkedApprovalOnABoundRun()
    let parker = CancellingParker(runs: env.runs, sessionId: env.sessionId, now: env.now)

    // when — the waiter's resolution drives the run terminal while it holds the lane
    await env.bootReconciler(waiter: parker).reconcile()
    _ = await env.lanes.drain(timeout: .seconds(5), clock: ContinuousClock())

    // then — the second lane closure settles too; the run does not wait for the next boot
    #expect(await parker.parkCount == 1)
    let receipt = try #require(try env.learning.settlement(runId: parked.runId))
    #expect(receipt.terminalCause == .ownerCancelled)
    #expect(receipt.settledAt != nil)
  }
}

// MARK: - Sealing Handoff

/// Yields until the sealing the notification queued has run. Not a wall-clock wait: the sealing
/// task only needs a turn on the executor, so the loop ends on the first turn after it commits.
private func waitUntilSealed(
  runId: Int64,
  in env: LaneSettlementEnvironment,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  for _ in 0..<10_000 {
    if try env.learning.evidence(runId: runId) != nil {
      return
    }
    await Task.yield()
  }
  Issue.record(
    "run \(runId) was never sealed after the lane tail notified",
    sourceLocation: sourceLocation
  )
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
  let service: ScheduledLearningService
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
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    // The fixture's first fire only establishes the job's session; the run it created is retired
    // so the overlap guard lets each test fire its own.
    try runs.failRun(runId: fired.runId, cause: .unknown, now: now)
    return LaneSettlementEnvironment(
      queue: queue,
      jobs: jobs,
      runs: runs,
      learning: learning,
      service: ScheduledLearningService(store: learning, now: { now }, logger: TestLog.silent),
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
      learning: service,
      now: { now },
      logger: TestLog.silent
    )
  }

  func cancellingDispatcher(error: (any Error)? = nil) -> CancellingDispatcher {
    CancellingDispatcher(runs: runs, sessionId: sessionId, now: now, error: error)
  }

  func bootReconciler(waiter: any ApprovalParking) -> ApprovalBootReconciler {
    ApprovalBootReconciler(
      approvals: ApprovalStoreGRDB(writer: queue),
      runs: runs,
      lanes: lanes,
      coordinator: ApprovalCoordinator(),
      waiter: waiter,
      learning: service,
      now: { now },
      logger: TestLog.silent
    )
  }

  /// A bound run suspended to AWAITING_APPROVAL with an unexpired PENDING approval — what boot
  /// finds in a reopened database and re-parks onto the session lane.
  func parkedApprovalOnABoundRun() throws -> (runId: Int64, approvalId: Int64) {
    let runId = try boundRun()
    let approvalId = try queue.write { db -> Int64 in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', ?, 'untrusted', ?, 'c1')
          """,
        arguments: [sessionId, runId, RunStoreGRDB.placeholderObservationContent, now]
      )
      let observationMessageId = db.lastInsertedRowID
      let canonicalArgsJSON = #"{"path":"/w/plan.md"}"#
      let approvalId = try ApprovalStoreGRDB.insertApproval(
        db,
        NewApproval(
          runId: runId,
          sessionId: sessionId,
          tool: "file_write",
          canonicalArgsJSON: canonicalArgsJSON,
          canonicalTarget: "/w/plan.md",
          argsHash: ApprovalArgsHash.sha256Hex(canonicalArgsJSON),
          policyVersion: "pv16",
          ownerUserId: 777,
          nonce: "n-parked",
          observationMessageId: observationMessageId,
          toolCallId: "c1",
          reason: .askTier,
          createdTs: now,
          expiresTs: now.addingTimeInterval(3_600)
        )
      )
      _ = try RunStoreGRDB.transitionRun(
        db,
        runId: runId,
        event: .suspendForApproval,
        now: now,
        terminal: nil
      )
      return approvalId
    }
    return (runId, approvalId)
  }
}

/// The boot-parked waiter's shape: it holds the lane, its resolution drives the run terminal with a
/// deferred receipt, and it returns. Modeled as `/stop` reaching the run while it is parked, which
/// is the reachable case that leaves a receipt this closure alone can settle.
private actor CancellingParker: ApprovalParking {
  private let runs: RunStoreGRDB
  private let sessionId: Int64
  private let now: Date

  private(set) var parkCount = 0

  init(runs: RunStoreGRDB, sessionId: Int64, now: Date) {
    self.runs = runs
    self.sessionId = sessionId
    self.now = now
  }

  func park(
    approvalId: Int64,
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    revalidatePolicyOnApprove: Bool
  ) async {
    parkCount += 1
    _ = try? runs.cancelActiveRun(sessionId: self.sessionId, reason: .cancelled, now: now)
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
