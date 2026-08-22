import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

@Suite struct ApprovalWaiterTests {
  // MARK: - Doubles

  /// A `Tool` double the executor runs on the approve path.
  private struct StubTool: Tool {
    let toolName: String
    let result: String
    var definition: ToolDefinition {
      ToolDefinition(
        name: toolName,
        description: "stub",
        parameters: .object(["type": .string("object")]),
        metadataProvenance: .trusted,
        egressClass: .none,
        riskLevel: .ask
      )
    }
    var timeout: Duration { .seconds(1) }

    func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }
    func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
      ToolPayload(content: result, status: .ok, ingestedUntrusted: false)
    }
  }

  /// Scripts the executor seam directly: the commit outcome the waiter must branch on.
  private struct ScriptedExecutor: ApprovedActionExecuting {
    let commit: ApprovedCommitOutcome

    func executeApproved(_ approval: Approval) async -> ApprovedCommitOutcome {
      commit
    }
  }

  /// An executor whose action only completes after `gate` releases — i.e. after typing fired once —
  /// standing in for a long sandbox run the owner would otherwise stare at in silence.
  private struct GatedExecutor: ApprovedActionExecuting {
    let gate: TypingReleaseGate

    func executeApproved(_ approval: Approval) async -> ApprovedCommitOutcome {
      await gate.awaitRelease()
      return .committed
    }
  }

  /// Captures whether the prompt keyboard was already disarmed when the action started
  /// executing — the owner-facing ordering the approve path must guarantee.
  private actor DisarmOrderProbeExecutor: ApprovedActionExecuting {
    private let callbacks: RecordingCallbacks
    private(set) var executed = false
    private(set) var disarmedBeforeExecution = false

    init(callbacks: RecordingCallbacks) {
      self.callbacks = callbacks
    }

    func executeApproved(_ approval: Approval) async -> ApprovedCommitOutcome {
      executed = true
      disarmedBeforeExecution = await !callbacks.disarmed.isEmpty
      return .committed
    }
  }

  /// Records `resume` calls; `run` is unused on the waiter path.
  private actor ResumeRecorder: TurnDispatching {
    struct ResumeCall: Sendable, Equatable {
      let runId: Int64
      let contextBoundMessageId: Int64
    }

    private(set) var resumeCalls: [ResumeCall] = []

    func run(
      runId: Int64,
      sessionId: Int64,
      chatId: Int64,
      triggerMessageId: Int64
    ) async throws {}

    func resume(
      runId: Int64,
      sessionId: Int64,
      chatId: Int64,
      contextBoundMessageId: Int64
    ) async {
      resumeCalls.append(ResumeCall(runId: runId, contextBoundMessageId: contextBoundMessageId))
    }
  }

  private actor RecordingDelivery: MessageDelivery {
    private(set) var texts: [String] = []

    func sendMessage(
      to target: DeliveryTarget,
      text: String,
      replyMarkup: String?
    ) async throws -> Int64 {
      texts.append(text)
      return 1
    }
    func sendRichMessage(
      to target: DeliveryTarget,
      markdown: String,
      replyMarkup: String?
    ) async throws -> Int64 { 1 }
  }

  private actor RecordingCallbacks: CallbackResponding {
    private(set) var disarmed: [Int64] = []

    func answerCallbackQuery(id: String, text: String?) async throws {}
    func editMessageReplyMarkup(
      chatId: Int64,
      messageId: Int64,
      replyMarkup: String?
    ) async throws {
      if replyMarkup == nil {
        disarmed.append(messageId)
      }
    }
  }

  // MARK: - Fixture

  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB
    let approvals: ApprovalStoreGRDB

    let sessionId: Int64
    let runId: Int64
    let approvalId: Int64
    let observationMessageId: Int64
    let promptMessageId: Int64
  }

  /// A suspended run with a placeholder observation and an APPROVED approvals row (seeded raw so
  /// the test does not depend on the Task-06 CAS internals; the waiter reads it via the real store).
  private func makeApprovedFixture(policyVersion: String = "pv") throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 7),
        chatId: 7,
        userId: 7,
        text: "write",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    let runs = RunStoreGRDB(writer: queue)
    _ = try #require(try runs.pickUp(runId: runId, now: Date()))

    let promptMessageId: Int64 = 900
    let argsJSON = #"{"path":"plan.md"}"#
    let observationMessageId = try queue.write { db -> Int64 in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', 'awaiting owner approval', 'untrusted', ?, 'c1')
          """,
        arguments: [sessionId, runId, Date()]
      )
      let messageId = db.lastInsertedRowID
      _ = try RunStoreGRDB.transitionRun(db, runId: runId, event: .suspendForApproval, now: Date())
      try db.execute(
        sql: """
          INSERT INTO approvals(run_id, session_id, state, tool, canonical_args, canonical_target,
            args_hash, policy_version, owner_user_id, nonce, observation_message_id, tool_call_id,
            reason, prompt_message_id, created_ts, expires_ts)
          VALUES (?, ?, 'APPROVED', 'file_write', ?, '/w/plan.md', ?, ?, 7, 'nonce-a', ?, 'c1',
            'ask_tier', ?, 1782000000, 1782003600)
          """,
        arguments: [
          runId, sessionId, argsJSON, ApprovalArgsHash.sha256Hex(argsJSON), policyVersion,
          messageId, promptMessageId,
        ]
      )
      return messageId
    }
    let approvalId = try queue.read { db in
      try #require(try Int64.fetchOne(db, sql: "SELECT id FROM approvals WHERE nonce = 'nonce-a'"))
    }

    return Fixture(
      queue: queue,
      runs: runs,
      approvals: ApprovalStoreGRDB(writer: queue),
      sessionId: sessionId,
      runId: runId,
      approvalId: approvalId,
      observationMessageId: observationMessageId,
      promptMessageId: promptMessageId
    )
  }

  private func makeWaiter(
    _ env: Fixture,
    coordinator: ApprovalCoordinator,
    turns: ResumeRecorder,
    delivery: RecordingDelivery,
    callbacks: RecordingCallbacks,
    currentPolicyVersion: @escaping @Sendable () throws -> String = { "pv" },
    executor: (any ApprovedActionExecuting)? = nil,
    typing: any TypingIndicator = NoopTyping(),
    clock: any Clock<Duration> = ContinuousClock()
  ) -> ApprovalWaiter {
    ApprovalWaiter(
      approvals: env.approvals,
      runs: env.runs,
      coordinator: coordinator,
      executor: executor
        ?? ApprovedActionExecutor(
          tools: ["file_write": StubTool(toolName: "file_write", result: "Wrote 12 B.")],
          runs: env.runs,
          redactArguments: { $0 },
          now: { Date() },
          logger: Logger(label: "test")
        ),
      turns: turns,
      delivery: delivery,
      callbacks: callbacks,
      typing: typing,
      clock: clock,
      currentPolicyVersion: currentPolicyVersion,
      now: { Date() },
      logger: Logger(label: "test")
    )
  }

  private func runState(_ env: Fixture) throws -> String? {
    try env.queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [env.runId])
    }
  }

  private func approvalState(_ env: Fixture) throws -> String? {
    try env.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT state FROM approvals WHERE id = ?",
        arguments: [env.approvalId]
      )
    }
  }

  // MARK: - Tests

  @Test func approveExecutesFillsResumesAndDisarms() async throws {
    // given
    let env = try makeApprovedFixture()
    let coordinator = ApprovalCoordinator()
    let turns = ResumeRecorder()
    let delivery = RecordingDelivery()
    let callbacks = RecordingCallbacks()
    let waiter = makeWaiter(
      env,
      coordinator: coordinator,
      turns: turns,
      delivery: delivery,
      callbacks: callbacks
    )

    // when — the coordinator buffers the signal, so park consumes it immediately (no polling)
    await coordinator.signal(approvalId: env.approvalId, .approved)
    await waiter.park(
      approvalId: env.approvalId,
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 7,
      revalidatePolicyOnApprove: false
    )

    // then — recorded args executed into the placeholder, run RUNNING, continuation bound to the
    // observation row, keyboard disarmed
    #expect(try runState(env) == RunState.running.rawValue)
    let observation = try await env.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT content FROM messages WHERE id = ?",
        arguments: [env.observationMessageId]
      )
    }
    #expect(observation == "Wrote 12 B.")
    #expect(
      await turns.resumeCalls == [
        .init(runId: env.runId, contextBoundMessageId: env.observationMessageId)
      ]
    )
    #expect(await callbacks.disarmed == [env.promptMessageId])
  }

  @Test func approveDisarmsTheButtonsBeforeTheActionExecutes() async throws {
    // given — an executor that records whether the keyboard was already gone when it started
    let env = try makeApprovedFixture()
    let coordinator = ApprovalCoordinator()
    let turns = ResumeRecorder()
    let delivery = RecordingDelivery()
    let callbacks = RecordingCallbacks()
    let executor = DisarmOrderProbeExecutor(callbacks: callbacks)
    let waiter = makeWaiter(
      env,
      coordinator: coordinator,
      turns: turns,
      delivery: delivery,
      callbacks: callbacks,
      executor: executor
    )

    // when
    await coordinator.signal(approvalId: env.approvalId, .approved)
    await waiter.park(
      approvalId: env.approvalId,
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 7,
      revalidatePolicyOnApprove: false
    )

    // then — the tap is acknowledged before the (possibly long) execution, not after it: the
    // approve CAS already made re-taps no-ops, so the keyboard must not outlive the decision
    #expect(await executor.executed)
    #expect(await executor.disarmedBeforeExecution)
    #expect(await callbacks.disarmed == [env.promptMessageId])
  }

  @Test(.timeLimit(.minutes(1)))
  func approveShowsTypingWhileTheActionExecutes() async throws {
    // given — an executor that cannot finish until the typing indicator has pulsed at least once,
    // and a clock whose reissue sleep parks until the race cancels it
    let env = try makeApprovedFixture()
    let coordinator = ApprovalCoordinator()
    let turns = ResumeRecorder()
    let delivery = RecordingDelivery()
    let callbacks = RecordingCallbacks()
    let gate = TypingReleaseGate()
    let typing = GatingTyping(gate: gate)
    let waiter = makeWaiter(
      env,
      coordinator: coordinator,
      turns: turns,
      delivery: delivery,
      callbacks: callbacks,
      executor: GatedExecutor(gate: gate),
      typing: typing,
      clock: ScriptedClock { _ in
        try await Task.sleep(for: .seconds(3600))
      }
    )

    // when
    await coordinator.signal(approvalId: env.approvalId, .approved)
    await waiter.park(
      approvalId: env.approvalId,
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 7,
      revalidatePolicyOnApprove: false
    )

    // then — the owner saw activity during the execution window, and the resume still ran
    #expect(await typing.calls >= 1)
    #expect(
      await turns.resumeCalls == [
        .init(runId: env.runId, contextBoundMessageId: env.observationMessageId)
      ]
    )
  }

  @Test func aStoreFailedCommitNotifiesTheOwnerAndLeavesTheRunAwaiting() async throws {
    // given — the executor reports the commit threw at the store seam (NOT a duplicate resume)
    let env = try makeApprovedFixture()
    let coordinator = ApprovalCoordinator()
    let turns = ResumeRecorder()
    let delivery = RecordingDelivery()
    let callbacks = RecordingCallbacks()
    let waiter = makeWaiter(
      env,
      coordinator: coordinator,
      turns: turns,
      delivery: delivery,
      callbacks: callbacks,
      executor: ScriptedExecutor(commit: .storeFailed)
    )

    // when
    await coordinator.signal(approvalId: env.approvalId, .approved)
    await waiter.park(
      approvalId: env.approvalId,
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 7,
      revalidatePolicyOnApprove: false
    )

    // then — no continuation, the owner is told, the buttons disarm, and the run STAYS
    // AWAITING_APPROVAL with the row APPROVED, so the boot crash-window path recovers the pair
    // after a restart (ApprovalBootReconcilerTests.approvedAwaitingRunReParksUnderCrashWindow-
    // Revalidation covers that recovery leg)
    #expect(try runState(env) == RunState.awaitingApproval.rawValue)
    #expect(try approvalState(env) == ApprovalState.approved.rawValue)
    #expect(await turns.resumeCalls.isEmpty)
    #expect(
      await delivery.texts == [
        "The approved action could not be recorded; it will be retried after a restart."
      ]
    )
    #expect(await callbacks.disarmed == [env.promptMessageId])
  }

  @Test func aRunNotResumableOutcomeDisarmsWithoutNoticeOrResume() async throws {
    // given — /stop won the claim race after the approve CAS; the executor reported it
    let env = try makeApprovedFixture()
    let coordinator = ApprovalCoordinator()
    let turns = ResumeRecorder()
    let delivery = RecordingDelivery()
    let callbacks = RecordingCallbacks()
    let waiter = makeWaiter(
      env,
      coordinator: coordinator,
      turns: turns,
      delivery: delivery,
      callbacks: callbacks,
      executor: ScriptedExecutor(commit: .runNotResumable)
    )

    // when
    await coordinator.signal(approvalId: env.approvalId, .approved)
    await waiter.park(
      approvalId: env.approvalId,
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 7,
      revalidatePolicyOnApprove: false
    )

    // then — no continuation and NO extra owner notice (the /stop//`new` ack already covered
    // it); the buttons still disarm
    #expect(await turns.resumeCalls.isEmpty)
    #expect(await delivery.texts.isEmpty)
    #expect(await callbacks.disarmed == [env.promptMessageId])
  }

  @Test func aRecordFailedOutcomeTellsTheOwnerTheActionRan() async throws {
    // given — the tool executed but recording its result threw; the copy must NOT promise a retry
    let env = try makeApprovedFixture()
    let coordinator = ApprovalCoordinator()
    let turns = ResumeRecorder()
    let delivery = RecordingDelivery()
    let callbacks = RecordingCallbacks()
    let waiter = makeWaiter(
      env,
      coordinator: coordinator,
      turns: turns,
      delivery: delivery,
      callbacks: callbacks,
      executor: ScriptedExecutor(commit: .recordFailed)
    )

    // when
    await coordinator.signal(approvalId: env.approvalId, .approved)
    await waiter.park(
      approvalId: env.approvalId,
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 7,
      revalidatePolicyOnApprove: false
    )

    // then
    #expect(await turns.resumeCalls.isEmpty)
    #expect(
      await delivery.texts == [
        "The approved action ran, but I couldn't record its result; a restart will settle things."
      ]
    )
    #expect(await callbacks.disarmed == [env.promptMessageId])
  }

  @Test func bootRevalidationOnPolicyMismatchFailsTheRunAndLeavesTheRowApproved() async throws {
    // given — the recorded policy_version no longer matches the current one (§6.5 crash window)
    let env = try makeApprovedFixture(policyVersion: "pv-old")
    let coordinator = ApprovalCoordinator()
    let turns = ResumeRecorder()
    let delivery = RecordingDelivery()
    let callbacks = RecordingCallbacks()
    let waiter = makeWaiter(
      env,
      coordinator: coordinator,
      turns: turns,
      delivery: delivery,
      callbacks: callbacks,
      currentPolicyVersion: { "pv-new" }
    )

    // when
    await coordinator.signal(approvalId: env.approvalId, .approved)
    await waiter.park(
      approvalId: env.approvalId,
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 7,
      revalidatePolicyOnApprove: true
    )

    // then — the RUN fails, the row stays APPROVED (the one granted-then-denied pair), no resume,
    // the owner gets a plain-language notice, and the placeholder observation is RESOLVED — left
    // dangling it would assert a pending approval to every later turn and false-trigger the boot
    // claimed-window settlement on the next restart
    #expect(try runState(env) == RunState.failed.rawValue)
    #expect(try approvalState(env) == ApprovalState.approved.rawValue)
    #expect(await turns.resumeCalls.isEmpty)
    #expect(await delivery.texts.isEmpty == false)
    let observation = try await env.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT content FROM messages WHERE id = ?",
        arguments: [env.observationMessageId]
      )
    }
    #expect(observation == "The approval was voided because the policy changed before it ran.")
    let auditDecision = try await env.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT decision FROM audit_events WHERE action = ? AND run_id = ?",
        arguments: [AuditAction.approvalDenied.rawValue, env.runId]
      )
    }
    #expect(auditDecision == ApprovalDecision.stalePolicy.rawValue)
  }

  @Test func denyFailsTheRunAndNotifiesTheOwner() async throws {
    // given — the deny half is a working stub here; Task 17 replaces the body with the synthetic
    // observation resolution. This asserts only the lane-freeing contract Task 16 must guarantee.
    let env = try makeApprovedFixture()
    let coordinator = ApprovalCoordinator()
    let turns = ResumeRecorder()
    let delivery = RecordingDelivery()
    let callbacks = RecordingCallbacks()
    let waiter = makeWaiter(
      env,
      coordinator: coordinator,
      turns: turns,
      delivery: delivery,
      callbacks: callbacks
    )

    // when
    await coordinator.signal(approvalId: env.approvalId, .denied(.rejected))
    await waiter.park(
      approvalId: env.approvalId,
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 7,
      revalidatePolicyOnApprove: false
    )

    // then — the lane is freed (run FAILED), the owner is told, and no continuation runs
    #expect(try runState(env) == RunState.failed.rawValue)
    #expect(await turns.resumeCalls.isEmpty)
    #expect(await delivery.texts.isEmpty == false)
    #expect(await callbacks.disarmed == [env.promptMessageId])
  }

  @Test func denySignalFillsPlaceholderObservationInPlace() async throws {
    // given — a parked waiter with the real deny half
    let env = try makeApprovedFixture()
    let coordinator = ApprovalCoordinator()
    let turns = ResumeRecorder()
    let delivery = RecordingDelivery()
    let callbacks = RecordingCallbacks()
    let waiter = makeWaiter(
      env,
      coordinator: coordinator,
      turns: turns,
      delivery: delivery,
      callbacks: callbacks
    )

    // when — an owner reject lands and the parked waiter finalizes it
    await coordinator.signal(approvalId: env.approvalId, .denied(.rejected))
    await waiter.park(
      approvalId: env.approvalId,
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 7,
      revalidatePolicyOnApprove: false
    )

    // then — the placeholder is REPLACED in place (no dangling tool_call), the run is FAILED, the
    // owner is notified, and the buttons are disarmed — via resolveDeniedObservation, not failRun
    let observation = try await env.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT content FROM messages WHERE id = ?",
        arguments: [env.observationMessageId]
      )
    }
    #expect(observation == "The owner declined this action.")
    #expect(try runState(env) == RunState.failed.rawValue)
    #expect(await turns.resumeCalls.isEmpty)
    #expect(await delivery.texts.isEmpty == false)
    #expect(await callbacks.disarmed == [env.promptMessageId])
  }

  // MARK: - Cancellation (carried-in liveness note #2)

  @Test(.timeLimit(.minutes(1)))
  func parkExitsCleanlyWhenCancelledWithoutResolution() async throws {
    // given — a genuinely parked waiter: no buffered signal, so park suspends on the coordinator
    let env = try makeApprovedFixture()
    let coordinator = ApprovalCoordinator()
    let turns = ResumeRecorder()
    let delivery = RecordingDelivery()
    let callbacks = RecordingCallbacks()
    let waiter = makeWaiter(
      env,
      coordinator: coordinator,
      turns: turns,
      delivery: delivery,
      callbacks: callbacks
    )

    // when — the lane task parks, then is cancelled with no resolution (graceful shutdown /
    // lane cancel). A leaked continuation would hang `await task.value`; the time limit turns that
    // regression into a failure instead of a wedged suite.
    let task = Task {
      await waiter.park(
        approvalId: env.approvalId,
        runId: env.runId,
        sessionId: env.sessionId,
        chatId: 7,
        revalidatePolicyOnApprove: false
      )
    }
    task.cancel()
    await task.value

    // then — park returned without resuming or denying; the durable row and run are untouched, so
    // Task 19 boot re-park rebuilds the hold on restart
    #expect(try runState(env) == RunState.awaitingApproval.rawValue)
    #expect(try approvalState(env) == ApprovalState.approved.rawValue)
    #expect(await turns.resumeCalls.isEmpty)
    #expect(await delivery.texts.isEmpty)
    #expect(await callbacks.disarmed.isEmpty)
  }
}
