import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData
@testable import ClawGateway

/// The lane closure is the only in-process owner of a deferred settlement. Boot reconciliation is
/// the crash backstop: a cancelled bound run whose settlement waited for the next daemon start
/// would fall out of the learning loop for as long as the daemon stays up.
@Suite
struct LaneSettlementTests {
  @Test
  func theLaneTailSettlesACancelledRunWithoutWaitingForBoot() async throws {
    // given — a bound run enqueued on its session lane, cancelled while the turn is in flight
    let env = try LaneSettlementEnvironment.make()
    let runID = try env.boundRun()
    let enqueuer = env.enqueuer(dispatcher: env.cancellingDispatcher())

    // when — the lane closure unwinds
    await enqueuer.enqueue(
      runID: runID,
      sessionID: env.sessionID,
      chatID: 777,
      triggerMessageID: try env.triggerMessageID(runID: runID)
    )
    let drained = await env.lanes.drain(timeout: .seconds(5), clock: ContinuousClock())

    // then — settlement happened in-process, not at the next boot
    #expect(drained == .drained)
    let receipt = try #require(try TestLearningFixtures(writer: env.queue).settlement(runID: runID))
    #expect(receipt.terminalCause == .ownerCancelled)
    #expect(receipt.settledAt != nil)
  }

  @Test
  func theLaneTailStillSettlesWhenTheTurnThrows() async throws {
    // given — the same cancellation, but the turn leaves through the `catch` arm
    let env = try LaneSettlementEnvironment.make()
    let runID = try env.boundRun()
    let dispatcher = env.cancellingDispatcher(error: StoreError.diskFull)
    let enqueuer = env.enqueuer(dispatcher: dispatcher)

    // when
    await enqueuer.enqueue(
      runID: runID,
      sessionID: env.sessionID,
      chatID: 777,
      triggerMessageID: try env.triggerMessageID(runID: runID)
    )
    _ = await env.lanes.drain(timeout: .seconds(5), clock: ContinuousClock())

    // then — every exit from the turn passes the tail, not just the happy one
    #expect(try TestLearningFixtures(writer: env.queue).settlement(runID: runID)?.settledAt != nil)
  }

  @Test
  func theLaneTailNotifiesTheSealerAndDoesNotOnlySettle() async throws {
    // given — the same cancelled bound run; nothing but the tail's own notification can put it in
    // front of the sealer before the next periodic sweep
    let env = try LaneSettlementEnvironment.make()
    let runID = try env.boundRun()
    let enqueuer = env.enqueuer(dispatcher: env.cancellingDispatcher())

    // when
    await enqueuer.enqueue(
      runID: runID,
      sessionID: env.sessionID,
      chatID: 777,
      triggerMessageID: try env.triggerMessageID(runID: runID)
    )
    _ = await env.lanes.drain(timeout: .seconds(5), clock: ContinuousClock())

    // then — a settlement with no notification would leave this receipt unwritten until a sweep
    try await waitUntilSealed(runID: runID, in: env)
    #expect(try env.learning.evidence(runID: runID) != nil)
  }

  @Test
  func theBootReparkedApprovalLaneCarriesTheSameTail() async throws {
    // given — a bound run parked on an unexpired approval, re-parked by boot onto its session lane;
    // `ApprovalBootReconciler` enqueues onto the registry itself rather than through `TurnEnqueuer`
    let env = try LaneSettlementEnvironment.make()
    let parked = try env.parkedApprovalOnABoundRun()
    let parker = CancellingParker(queue: env.queue, now: env.now)

    // when — the waiter's resolution drives the run terminal while it holds the lane
    await env.bootReconciler(waiter: parker).reconcile()
    _ = await env.lanes.drain(timeout: .seconds(5), clock: ContinuousClock())

    // then — the second lane closure settles too; the run does not wait for the next boot
    #expect(await parker.parkCount == 1)
    let receipt = try #require(
      try TestLearningFixtures(writer: env.queue).settlement(runID: parked.runID)
    )
    #expect(receipt.terminalCause == .ownerCancelled)
    #expect(receipt.settledAt != nil)
  }

  @Test
  func bootReconcilesTheOperationsAPriorProcessLeftOpen() async throws {
    // given — a claim the last process took and never authorized
    let env = try LaneSettlementEnvironment.make()
    try env.seedClaimedOperation(id: "op-1")

    // when — the daemon's own boot pass runs, not the store call underneath it
    await env.service.reconcileAtBoot(now: env.now)

    // then — sealing alone would leave this row the current generation forever, and the run
    // behind it would never be evaluated
    #expect(try env.operationState(id: "op-1") == .pending)
  }
}

// MARK: - Sealing Handoff

/// Yields until the sealing the notification queued has run. Not a wall-clock wait: the sealing
/// task only needs a turn on the executor, so the loop ends on the first turn after it commits.
private func waitUntilSealed(
  runID: Int64,
  in env: LaneSettlementEnvironment,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  for _ in 0..<10_000 {
    if try env.learning.evidence(runID: runID) != nil {
      return
    }
    await Task.yield()
  }
  Issue.record(
    "run \(runID) was never sealed after the lane tail notified",
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
  let jobID: Int64
  let sessionID: Int64
  let now: Date

  static func make() throws -> LaneSettlementEnvironment {
    let queue = try TestDatabase.make()
    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let now = Date(timeIntervalSince1970: 1_782_000_600)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatID: 777,
        label: "digest",
        prompt: "Summarize my unread items",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
    guard case .fired(let fired) = try jobs.fireNow(jobID: job.id, now: now) else {
      throw StoreError.unexpected("job \(job.id) refused to fire")
    }
    let runs = RunStoreGRDB(writer: queue)
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    // The fixture's first fire only establishes the job's session; the run it created is retired
    // so the overlap guard lets each test fire its own.
    try runs.failRun(runID: fired.runID, cause: .unknown, now: now)
    return LaneSettlementEnvironment(
      queue: queue,
      jobs: jobs,
      runs: runs,
      learning: learning,
      service: ScheduledLearningService(
        store: learning,
        now: {
          now
        },
        logger: TestLog.silent
      ),
      lanes: SessionLaneRegistry(),
      jobID: job.id,
      sessionID: fired.sessionID,
      now: now
    )
  }

  func boundRun() throws -> Int64 {
    guard case .fired(let fired) = try jobs.fireNow(jobID: jobID, now: now) else {
      throw StoreError.unexpected("job \(jobID) refused to fire")
    }
    _ = try runs.pickUp(runID: fired.runID, now: now)
    return fired.runID
  }

  func triggerMessageID(runID: Int64) throws -> Int64 {
    try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT trigger_message_id FROM runs WHERE id = ?",
        arguments: [runID]
      ) ?? 0
    }
  }

  func enqueuer(dispatcher: any TurnDispatching) -> TurnEnqueuer {
    TurnEnqueuer(
      lanes: lanes,
      turns: dispatcher,
      learning: service,
      now: {
        now
      },
      logger: TestLog.silent
    )
  }

  /// A `learning_operations` row written straight to the table: the durable shape a process that
  /// died between the claim and the authorization leaves, with none of the sealing and claiming
  /// this suite is not about.
  func seedClaimedOperation(id: String) throws {
    try queue.write { db in
      try db.execute(
        sql: """
        INSERT INTO learning_operations(operation_id, job_id, learning_epoch, phase,
          source_digest, attempt_generation, state, key_digest, created_at)
        VALUES (?, ?, 1, ?, 'evidence', 1, ?, ?, 0)
        """,
        arguments: [
          id,
          jobID,
          LearningPhase.evaluator.rawValue,
          LearningOperationState.claimed.rawValue,
          "key-\(id)",
        ]
      )
    }
  }

  func operationState(id: String) throws -> LearningOperationState? {
    try queue.read { db in
      let raw = try String.fetchOne(
        db,
        sql: "SELECT state FROM learning_operations WHERE operation_id = ?",
        arguments: [id]
      )
      return raw.flatMap(LearningOperationState.init(rawValue:))
    }
  }

  func cancellingDispatcher(error: (any Error)? = nil) -> CancellingDispatcher {
    CancellingDispatcher(queue: queue, now: now, error: error)
  }

  func bootReconciler(waiter: any ApprovalParking) -> ApprovalBootReconciler {
    ApprovalBootReconciler(
      approvals: ApprovalStoreGRDB(writer: queue),
      runs: runs,
      lanes: lanes,
      coordinator: ApprovalCoordinator(),
      waiter: waiter,
      learning: service,
      now: {
        now
      },
      logger: TestLog.silent
    )
  }

  /// A bound run suspended to AWAITING_APPROVAL with an unexpired PENDING approval — what boot
  /// finds in a reopened database and re-parks onto the session lane.
  func parkedApprovalOnABoundRun() throws -> (runID: Int64, approvalID: Int64) {
    let runID = try boundRun()
    let approvalID = try queue.write { db -> Int64 in
      try db.execute(
        sql: """
        INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
        VALUES (?, ?, 'tool', ?, 'untrusted', ?, 'c1')
        """,
        arguments: [sessionID, runID, RunStoreGRDB.placeholderObservationContent, now]
      )
      let observationMessageID = db.lastInsertedRowID
      let canonicalArgsJSON = #"{"path":"/w/plan.md"}"#
      let approvalID = try ApprovalStoreGRDB.insertApproval(
        db,
        NewApproval(
          runID: runID,
          sessionID: sessionID,
          tool: "file_write",
          canonicalArgsJSON: canonicalArgsJSON,
          canonicalTarget: "/w/plan.md",
          argsHash: ApprovalArgsHash.sha256Hex(canonicalArgsJSON),
          policyVersion: "pv16",
          ownerUserID: 777,
          nonce: "n-parked",
          observationMessageID: observationMessageID,
          toolCallID: "c1",
          reason: .askTier,
          createdTs: now,
          expiresTs: now.addingTimeInterval(3_600)
        )
      )
      _ = try RunStoreGRDB.transitionRun(
        db,
        runID: runID,
        event: .suspendForApproval,
        now: now,
        terminal: nil
      )
      return approvalID
    }
    return (runID, approvalID)
  }
}

/// Leaves a deferred terminal receipt while the boot-parked waiter holds the lane.
private actor CancellingParker: ApprovalParking {
  private let queue: DatabaseQueue
  private let now: Date

  private(set) var parkCount = 0

  init(queue: DatabaseQueue, now: Date) {
    self.queue = queue
    self.now = now
  }

  func park(
    approvalID: Int64,
    runID: Int64,
    sessionID: Int64,
    chatID: Int64,
    revalidatePolicyOnApprove: Bool
  ) async {
    parkCount += 1
    _ = try? await queue.write { db in
      try RunStoreGRDB.transitionRun(
        db,
        runID: runID,
        event: .cancel,
        now: self.now,
        terminal: .deferred(.ownerCancelled)
      )
    }
  }
}

/// Leaves a deferred terminal receipt before the turn returns or throws.
private struct CancellingDispatcher: TurnDispatching {
  let queue: DatabaseQueue
  let now: Date
  let error: (any Error)?

  func run(runID: Int64, sessionID: Int64, chatID: Int64, triggerMessageID: Int64) async throws {
    _ = try await queue.write { db in
      try RunStoreGRDB.transitionRun(
        db,
        runID: runID,
        event: .cancel,
        now: now,
        terminal: .deferred(.ownerCancelled)
      )
    }
    if let error {
      throw error
    }
  }
}
