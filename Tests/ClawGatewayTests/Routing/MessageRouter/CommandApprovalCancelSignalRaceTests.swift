import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawData
@testable import ClawGateway

@Suite
struct CommandApprovalCancelSignalRaceTests {
  private static let paddingRuns = 96

  private static let cycles = 6

  // MARK: - Doubles

  private struct InertExecutor: ApprovedActionExecuting {
    func executeApproved(_ approval: Approval) async -> ApprovedCommitOutcome { .ignored }
  }

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
    let sessionID: Int64
    let runID: Int64
    let approvalID: Int64
    let observationMessageID: Int64
    let chatID: Int64
  }

  // MARK: - Tests

  @Test(.timeLimit(.minutes(1)))
  func liveStopFillsTheParkedObservationAndFreesTheLaneEveryCycle() async throws {
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
  func runLiveCommandCycle(command: String) async throws -> String? {
    let harness = try makeHarness()
    let waiter = makeWaiter(harness)
    let laneFreed = Latch()

    _ = await harness.lanes.enqueue(sessionID: harness.sessionID, runID: harness.runID) {
      await waiter.park(
        approvalID: harness.approvalID,
        runID: harness.runID,
        sessionID: harness.sessionID,
        chatID: harness.chatID,
        revalidatePolicyOnApprove: false
      )
    }

    let trailingRunID = harness.runID + 1_000_000
    _ = await harness.lanes.enqueue(sessionID: harness.sessionID, runID: trailingRunID) {
      await laneFreed.open()
    }

    for _ in 0..<16 {
      await Task.yield()
    }

    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 9_999, from: harness.chatID, text: command)
    )
    #expect(outcome == .processed)

    await laneFreed.wait()

    return try await harness.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT content FROM messages WHERE id = ?",
        arguments: [harness.observationMessageID]
      )
    }
  }
}

// MARK: - Builders

private extension CommandApprovalCancelSignalRaceTests {
  private func makeHarness() throws -> Harness {
    let chatID: Int64 = 42
    let queue = try TestDatabase.make()
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIDs: [chatID])

    let sessions = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)

    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: chatID),
        chatID: chatID,
        userID: chatID,
        text: "write the plan",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionID = try #require(claim.sessionID)
    let runID = try #require(claim.runID)
    _ = try #require(try runs.pickUp(runID: runID, now: Date()))

    try seedPadding(queue: queue, sessionID: sessionID)

    let observationMessageID = try seedParkedApproval(
      queue: queue,
      sessionID: sessionID,
      runID: runID
    )
    let approvalID = try queue.read { db in
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
      botIdentity: BotIdentity(id: 900, username: "claw_bot"),
      accessControl: AccessControl(allowlist: allowlist, groupChats: []),
      delivery: RecordingTransport(),
      turnRunner: FakeTurnRunner(),
      imageCache: ImageCache(),
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
      sessionID: sessionID,
      runID: runID,
      approvalID: approvalID,
      observationMessageID: observationMessageID,
      chatID: chatID
    )
  }

  func seedPadding(queue: DatabaseQueue, sessionID: Int64) throws {
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
          arguments: [sessionID, RunState.running.rawValue, now, now]
        )
        let paddingRunID = db.lastInsertedRowID
        try db.execute(
          sql: """
          INSERT INTO approvals(run_id, session_id, state, tool, canonical_args, canonical_target,
            args_hash, policy_version, owner_user_id, nonce, observation_message_id, tool_call_id,
            reason, created_ts, expires_ts)
          VALUES (?, ?, 'PENDING', 'file_write', ?, '/w/pad.md', ?, 'pv', 42, ?, 0, ?,
            'ask_tier', 1782000000, 1782003600)
          """,
          arguments: [paddingRunID, sessionID, argsJSON, argsHash, "pad-\(index)", "pad-c\(index)"]
        )
      }
    }
  }

  func seedParkedApproval(queue: DatabaseQueue, sessionID: Int64, runID: Int64) throws -> Int64 {
    let now = Date()
    let argsJSON = #"{"path":"/w/plan.md"}"#
    return try queue.write { db -> Int64 in
      try db.execute(
        sql: """
        INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
        VALUES (?, ?, 'tool', ?, 'untrusted', ?, 'c1')
        """,
        arguments: [sessionID, runID, RunStoreGRDB.placeholderObservationContent, now]
      )
      let observationMessageID = db.lastInsertedRowID
      _ = try RunStoreGRDB.transitionRun(
        db,
        runID: runID,
        event: .suspendForApproval,
        now: now,
        terminal: nil
      )
      try db.execute(
        sql: """
        INSERT INTO approvals(run_id, session_id, state, tool, canonical_args, canonical_target,
          args_hash, policy_version, owner_user_id, nonce, observation_message_id, tool_call_id,
          reason, prompt_message_id, created_ts, expires_ts)
        VALUES (?, ?, 'PENDING', 'file_write', ?, '/w/plan.md', ?, 'pv', 42, 'nonce-a', ?, 'c1',
          'ask_tier', 900, 1782000000, 1782003600)
        """,
        arguments: [
          runID,
          sessionID,
          argsJSON,
          ApprovalArgsHash.sha256Hex(argsJSON),
          observationMessageID,
        ]
      )
      return observationMessageID
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
      currentPolicyVersion: {
        "pv"
      },
      now: {
        Date()
      },
      logger: TestLog.silent
    )
  }
}
