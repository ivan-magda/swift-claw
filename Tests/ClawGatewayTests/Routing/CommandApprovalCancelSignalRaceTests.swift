import ClawAgent
import ClawCore
import ClawTestSupport
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
/// To make the nil-resume win the race deterministically the session carries padding: `paddingRuns`
/// extra cancellable runs, each with its own PENDING approval, plus the real parked run/approval.
/// The parked run has the lowest run id and the real approval the HIGHEST approval id (padding is
/// seeded first), which stretches the deferral window each command opens between spawning the
/// detached `cancelWaiter` and delivering the real signal:
///
/// - `/stop` cancels the parked run FIRST (lowest id, ascending order) — spawning its detached
///   cancel task — then makes one `await lane.cancel` hop per padding run before the signal loop.
/// - `/new` cancels the whole lane in one `cancelAll()`, so it has no per-run cancel loop; instead
///   the real approval (highest id) is signalled LAST, deferred behind one `await coordinator.signal`
///   hop per padding approval.
///
/// Either way the detached `cancelWaiter` gets a long head start, so under one cooperative thread
/// (`SWIFT_MAX_CONCURRENCY_THREADS=1`, the project's nproc=1 convention for concurrency tests) it
/// reaches the coordinator before the signal and the pre-fix code leaves the placeholder dangling on
/// essentially every cycle. On a multi-threaded scheduler the atomic `signal` wins, so the pre-fix
/// bug does not surface there. The fixed ordering signals before any cancel, so the fill lands on
/// every cycle under either scheduler.
@Suite struct CommandApprovalCancelSignalRaceTests {
  /// Extra cancellable runs (each carrying a PENDING approval) that pad the command's cancel loop
  /// (`/stop`) and signal loop (`/new`), deferring the real approval's signal long enough for the
  /// detached cancel task to win the pre-fix race under cooperative scheduling. Sized so both
  /// commands catch the pre-fix bug on ~99% of cycles at nproc=1 (empirically measured).
  private static let paddingRuns = 96

  /// Cycles per test. The padding above — not the cycle count — is the determinism mechanism, so
  /// cycles are redundant Bernoulli trials: at the measured ~99% per-cycle catch six cycles miss
  /// with probability ~1e-12, and even a scheduler that degraded the rate to 90% would still miss
  /// at under 1e-6. More cycles buy nothing but wall-clock.
  private static let cycles = 6

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
    for cycle in 0..<Self.cycles {
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
    for cycle in 0..<Self.cycles {
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

    _ = await harness.lanes.enqueue(sessionID: harness.sessionId, runID: harness.runId) {
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
    _ = await harness.lanes.enqueue(sessionID: harness.sessionId, runID: trailingRunId) {
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

    // Padding is seeded BEFORE the real approval so the real approval holds the HIGHEST approval id
    // and is therefore signalled LAST (`resolvePendingApprovals` orders by id ASC) — see below.
    try seedPadding(queue: queue, sessionId: sessionId)

    let observationMessageId = try seedParkedApproval(
      queue: queue,
      sessionId: sessionId,
      runId: runId
    )
    let approvalId = try queue.read { db in
      try #require(try Int64.fetchOne(db, sql: "SELECT id FROM approvals WHERE nonce = 'nonce-a'"))
    }

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
      doctor: StubDoctorReporter(),
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

  /// Extra RUNNING runs, each carrying its own PENDING approval, in the same session. They pad BOTH
  /// deferral windows the pre-fix bug races against:
  ///
  /// - `/stop` loops `for runId in cancelledRunIds { await lane.cancel(runId) }`, so each padding
  ///   RUN adds one no-op `lane.cancel` await hop before the signal loop.
  /// - `/new` calls `lane.cancelAll()` once (no per-run loop), so runs alone can't defer its signal.
  ///   Instead each padding APPROVAL adds one `await coordinator.signal` hop to the signal loop; the
  ///   real approval has the highest id (seeded last) so it is signalled LAST, deferred behind all
  ///   of them — long enough for the parked waiter's detached cancel task to win the race.
  ///
  /// The command path reads only their `id`/`state`, so they are inserted raw in a SINGLE
  /// transaction — the old per-run `claimAndPersistInbound` + `pickUp` path cost two write
  /// transactions each and dominated the fixture's setup time.
  func seedPadding(queue: DatabaseQueue, sessionId: Int64) throws {
    let now = Date()
    let argsJSON = #"{"path":"/w/pad.md"}"#
    let argsHash = ApprovalArgsHash.sha256Hex(argsJSON)
    try queue.write { db in
      for index in 0..<Self.paddingRuns {
        try db.execute(
          sql: """
            INSERT INTO runs(session_id, state, created_ts, updated_ts)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [sessionId, RunState.running.rawValue, now, now]
        )
        let paddingRunId = db.lastInsertedRowID
        try db.execute(
          sql: """
            INSERT INTO approvals(run_id, session_id, state, tool, canonical_args, canonical_target,
              args_hash, policy_version, owner_user_id, nonce, observation_message_id, tool_call_id,
              reason, created_ts, expires_ts)
            VALUES (?, ?, 'PENDING', 'file_write', ?, '/w/pad.md', ?, 'pv', 42, ?, 0, ?,
              'ask_tier', 1782000000, 1782003600)
            """,
          arguments: [
            paddingRunId, sessionId, argsJSON, argsHash, "pad-\(index)", "pad-c\(index)",
          ]
        )
      }
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
      typing: NoopTyping(),
      clock: ContinuousClock(),
      currentPolicyVersion: { "pv" },
      now: { Date() },
      logger: TestLog.silent
    )
  }
}
