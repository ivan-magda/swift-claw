import ClawAgent
import ClawCore
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawData
@testable import ClawGateway

/// Guards the Task-17 follow-up fix: `CommandHandlers.stop`/`new` must signal the
/// `ApprovalCoordinator` BEFORE cancelling the session lane. A genuinely parked `ApprovalWaiter`
/// (awaiting the coordinator on the lane, no pre-buffered signal) then always consumes a real
/// `.denied` and fills its synthetic observation in place; the subsequent lane cancel can only
/// no-op the already-resumed waiter.
///
/// Under the pre-fix ordering (cancel, then signal) the lane cancel resumes the parked waiter with
/// `nil` via the coordinator's cancellation path (a detached `Task` running `cancelWaiter`), which
/// races the later signal. When the nil-resume wins, `park` exits early and never fills the
/// placeholder — a dangling "awaiting owner approval" tool_call is left on the now-terminal run.
///
/// To make the nil-resume win the race deterministically, the session carries extra cancellable
/// runs: the parked run has the lowest id, so `/stop`//`new` cancel it FIRST (spawning its detached
/// cancel task) while its `signal` is deferred behind every other run's `lane.cancel` hop. Under one
/// cooperative thread (`SWIFT_MAX_CONCURRENCY_THREADS=1`, the project's nproc=1 convention for
/// concurrency tests) that head start lets `cancelWaiter` reach the coordinator before the signal, so
/// the pre-fix code leaves the placeholder dangling. On a multi-threaded scheduler the atomic
/// `signal` wins, so the pre-fix bug does not surface there. The fixed ordering signals before any
/// cancel, so the fill lands on every cycle under either scheduler.
@Suite struct CommandApprovalCancelSignalRaceTests {
  /// Extra cancellable runs queued ahead of the parked approval's signal in the command's cancel
  /// loop — they defer the signal enough for the parked run's detached cancel task to win the
  /// pre-fix race under cooperative FIFO scheduling.
  private static let paddingRuns = 64

  // MARK: - Doubles

  /// The waiter's approve-path collaborator is unused on the deny/cancel path; a no-op stub keeps
  /// the fixture focused on the resolution the command triggers.
  private struct InertExecutor: ApprovedActionExecuting {
    func executeApproved(_ approval: Approval) async -> ApprovedExecutionOutcome {
      ApprovedExecutionOutcome(observationContent: "", commit: .ignored)
    }
  }

  /// A one-shot rendezvous the trailing lane unit opens once it runs — proving the lane drained.
  private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
      isOpen = true
      for waiter in waiters {
        waiter.resume()
      }
      waiters.removeAll()
    }

    func wait() async {
      guard isOpen == false else {
        return
      }
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }
  }

  // MARK: - Fixture

  private struct Harness {
    let router: MessageRouter
    let queue: DatabaseQueue
    let lanes: SessionLaneRegistry
    let coordinator: ApprovalCoordinator
    let sessionId: Int64
    let runId: Int64
    let approvalId: Int64
    let observationMessageId: Int64
    let chatId: Int64
  }

  // MARK: - Tests

  @Test(.timeLimit(.minutes(1)))
  func liveStopFillsTheParkedObservationAndFreesTheLaneEveryCycle() async throws {
    // The pre-fix (cancel-then-signal) ordering fails this: the parked waiter's nil-resume wins the
    // race and skips the fill. The fixed ordering fills the observation on every cycle.
    for cycle in 0..<40 {
      // given / when
      let observation = try await runLiveCommandCycle(command: "/stop")

      // then — the placeholder was replaced in place, proving resolveDeniedObservation ran (the
      // signal was consumed before the cancel); reaching here proves the lane drained.
      #expect(
        observation == "Cancelled by /stop.",
        "cycle \(cycle): the parked approval left a dangling placeholder"
      )
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func liveNewFillsTheParkedObservationAndFreesTheLaneEveryCycle() async throws {
    for cycle in 0..<40 {
      // given / when
      let observation = try await runLiveCommandCycle(command: "/new")

      // then
      #expect(
        observation == "Superseded by /new.",
        "cycle \(cycle): the parked approval left a dangling placeholder"
      )
    }
  }
}

// MARK: - Cycle

private extension CommandApprovalCancelSignalRaceTests {
  /// Parks a real waiter on the session lane (genuinely awaiting the coordinator), queues a plain
  /// unit behind it, drives one live command through the router, waits for the lane to drain, and
  /// returns the observation content the resolution left behind.
  func runLiveCommandCycle(command: String) async throws -> String? {
    let harness = try makeHarness()
    let waiter = makeWaiter(harness)
    let laneFreed = Latch()

    let lane = await harness.lanes.actor(for: harness.sessionId)
    await lane.enqueue(runId: harness.runId) {
      await waiter.park(
        approvalId: harness.approvalId,
        runId: harness.runId,
        sessionId: harness.sessionId,
        chatId: harness.chatId,
        revalidatePolicyOnApprove: false
      )
    }
    // A plain unit of lane work queued BEHIND the park: FIFO chaining means it can only run once
    // the parked waiter completes, so its execution proves the lane was freed.
    let trailingRunId = harness.runId + 1_000_000
    await lane.enqueue(runId: trailingRunId) {
      await laneFreed.open()
    }

    // Let the parked waiter reach its coordinator registration before the command resolves it, so
    // this exercises the live cancel-vs-signal window rather than a pre-buffered signal. Yields are
    // cooperative (never block a thread), so this is safe at nproc=1.
    for _ in 0..<16 {
      await Task.yield()
    }

    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 9_999, from: harness.chatId, text: command)
    )
    #expect(outcome == .processed)

    await laneFreed.wait()

    return try await harness.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT content FROM messages WHERE id = ?",
        arguments: [harness.observationMessageId]
      )
    }
  }
}

// MARK: - Builders

private extension CommandApprovalCancelSignalRaceTests {
  private func makeHarness() throws -> Harness {
    let chatId: Int64 = 42
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: [chatId])

    let sessions = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)

    // The parked run is seeded FIRST so it holds the lowest run id and is cancelled first (`/stop`
    // cancels in ascending id order) — its detached cancel task then races ahead of the signal.
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: chatId),
        chatId: chatId,
        userId: chatId,
        text: "write the plan",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    _ = try #require(try runs.pickUp(runId: runId, now: Date()))
    let observationMessageId = try seedParkedApproval(
      queue: queue,
      sessionId: sessionId,
      runId: runId
    )
    let approvalId = try queue.read { db in
      try #require(try Int64.fetchOne(db, sql: "SELECT id FROM approvals WHERE nonce = 'nonce-a'"))
    }

    try seedPaddingRuns(sessions: sessions, runs: runs, chatId: chatId)

    let coordinator = ApprovalCoordinator()
    let lanes = SessionLaneRegistry()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: sessions,
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist),
      delivery: RecordingTransport(),
      turnRunner: FakeTurnRunner(),
      lanes: lanes,
      schedule: makeIdleScheduleSurface(writer: queue),
      coordinator: coordinator,
      logger: TestLog.silent
    )

    return Harness(
      router: router,
      queue: queue,
      lanes: lanes,
      coordinator: coordinator,
      sessionId: sessionId,
      runId: runId,
      approvalId: approvalId,
      observationMessageId: observationMessageId,
      chatId: chatId
    )
  }

  /// Extra RUNNING runs in the same session. They carry no approval, so they only pad the command's
  /// cancel loop, deferring the parked approval's signal behind their `lane.cancel` hops.
  func seedPaddingRuns(
    sessions: SessionMessageStoreGRDB,
    runs: RunStoreGRDB,
    chatId: Int64
  ) throws {
    for index in 0..<Self.paddingRuns {
      let paddingClaim = try sessions.claimAndPersistInbound(
        InboundMessage(
          updateId: Int64(1_000 + index),
          sessionKey: SessionKey.telegramDM(chatId: chatId),
          chatId: chatId,
          userId: chatId,
          text: "padding \(index)",
          isEdited: false,
          ts: Date()
        )
      )
      let paddingRunId = try #require(paddingClaim.runId)
      _ = try #require(try runs.pickUp(runId: paddingRunId, now: Date()))
    }
  }

  /// Suspends the run at AWAITING_APPROVAL behind a placeholder tool observation and a PENDING
  /// approval — the exact shape `/stop`//`new` must resolve. Returns the observation row id the
  /// resolution must fill in place. Seeded raw so the fixture does not depend on Task-06 CAS
  /// internals; the command path and waiter read it through the real stores.
  func seedParkedApproval(queue: DatabaseQueue, sessionId: Int64, runId: Int64) throws -> Int64 {
    let now = Date()
    let argsJSON = #"{"path":"/w/plan.md"}"#
    return try queue.write { db -> Int64 in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', ?, 'untrusted', ?, 'c1')
          """,
        arguments: [sessionId, runId, RunStoreGRDB.placeholderObservationContent, now]
      )
      let observationMessageId = db.lastInsertedRowID
      _ = try RunStoreGRDB.transitionRun(db, runId: runId, event: .suspendForApproval, now: now)
      try db.execute(
        sql: """
          INSERT INTO approvals(run_id, session_id, state, tool, canonical_args, canonical_target,
            args_hash, policy_version, owner_user_id, nonce, observation_message_id, tool_call_id,
            reason, prompt_message_id, created_ts, expires_ts)
          VALUES (?, ?, 'PENDING', 'file_write', ?, '/w/plan.md', ?, 'pv', 42, 'nonce-a', ?, 'c1',
            'ask_tier', 900, 1782000000, 1782003600)
          """,
        arguments: [
          runId, sessionId, argsJSON, ApprovalArgsHash.sha256Hex(argsJSON), observationMessageId,
        ]
      )
      return observationMessageId
    }
  }

  private func makeWaiter(_ harness: Harness) -> ApprovalWaiter {
    let transport = RecordingTransport()
    return ApprovalWaiter(
      approvals: ApprovalStoreGRDB(writer: harness.queue),
      runs: RunStoreGRDB(writer: harness.queue),
      coordinator: harness.coordinator,
      executor: InertExecutor(),
      turns: FakeTurnRunner(),
      delivery: transport,
      callbacks: transport,
      currentPolicyVersion: { "pv" },
      now: { Date() },
      logger: TestLog.silent
    )
  }
}
