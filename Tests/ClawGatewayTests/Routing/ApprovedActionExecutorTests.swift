import ClawCore
import ClawData
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

@Suite struct ApprovedActionExecutorTests {
  /// Records whether a tool double's `execute` ever ran — the cancel-race tests assert a claimed
  /// terminal run means the external effect NEVER starts.
  private actor ExecutionProbe {
    private(set) var executed = false

    func mark() {
      executed = true
    }
  }

  private actor ExecutionGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
      started = true
      for waiter in startedWaiters {
        waiter.resume()
      }
      startedWaiters.removeAll()
      guard released == false else {
        return
      }
      await withCheckedContinuation { continuation in
        releaseWaiters.append(continuation)
      }
    }

    func waitUntilStarted() async {
      guard started == false else {
        return
      }
      await withCheckedContinuation { continuation in
        startedWaiters.append(continuation)
      }
    }

    func release() {
      released = true
      for waiter in releaseWaiters {
        waiter.resume()
      }
      releaseWaiters.removeAll()
    }
  }

  private struct RecordingWriteTool: Tool {
    let toolName: String
    let payload: ToolPayload
    let gate: ExecutionGate?
    let probe: ExecutionProbe?

    init(
      toolName: String,
      result: String,
      status: ToolObservationStatus = .ok,
      ingestedUntrusted: Bool = false,
      readPrivateData: Bool = false,
      gate: ExecutionGate? = nil,
      probe: ExecutionProbe? = nil
    ) {
      self.toolName = toolName
      payload = ToolPayload(
        content: result,
        status: status,
        ingestedUntrusted: ingestedUntrusted,
        readPrivateData: readPrivateData
      )
      self.gate = gate
      self.probe = probe
    }

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

    var timeout: Duration { .milliseconds(1) }

    func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

    func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
      await probe?.mark()
      await gate?.arriveAndWait()
      return payload
    }
  }

  /// Reports the run's LIVE state as its result, so a test can pin down what the run row said at
  /// the moment the tool body ran.
  private struct RunStateReportingTool: Tool {
    let queue: DatabaseQueue
    let runId: Int64

    var definition: ToolDefinition {
      ToolDefinition(
        name: "file_write",
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
      let state =
        (try? await queue.read { db in
          try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
        }) ?? "unreadable"
      return ToolPayload(content: state, status: .ok, ingestedUntrusted: false)
    }
  }

  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB
    let sessionId: Int64
    let runId: Int64
    let observationMessageId: Int64
  }

  private func makeSuspendedFixture() throws -> Fixture {
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
      return messageId
    }
    return Fixture(
      queue: queue,
      runs: runs,
      sessionId: sessionId,
      runId: runId,
      observationMessageId: observationMessageId
    )
  }

  private func approval(
    _ env: Fixture,
    tool: String,
    argsJSON: String,
    target: String = "/w/plan.md"
  ) -> Approval {
    Approval(
      id: 1,
      runId: env.runId,
      sessionId: env.sessionId,
      state: .approved,
      tool: tool,
      canonicalArgsJSON: argsJSON,
      canonicalTarget: target,
      argsHash: ApprovalArgsHash.sha256Hex(argsJSON),
      policyVersion: "pv",
      ownerUserId: 7,
      nonce: "nonce-a",
      observationMessageId: env.observationMessageId,
      toolCallId: "c1",
      reason: .askTier,
      promptMessageId: 900,
      createdTs: Date(),
      expiresTs: Date(),
      resolvedTs: Date()
    )
  }

  private func makeExecutor(
    _ env: Fixture,
    tools: [any Tool],
    runs: (any RunStore)? = nil,
    redactArguments: @escaping @Sendable (String) -> String = { $0 }
  ) -> ApprovedActionExecutor {
    ApprovedActionExecutor(
      tools: Dictionary(uniqueKeysWithValues: tools.map { ($0.definition.name, $0) }),
      runs: runs ?? env.runs,
      redactArguments: redactArguments,
      now: { Date() },
      logger: Logger(label: "test")
    )
  }

  private func messageContent(_ env: Fixture) throws -> String? {
    try env.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT content FROM messages WHERE id = ?",
        arguments: [env.observationMessageId]
      )
    }
  }

  private func runState(_ env: Fixture) throws -> String? {
    try env.queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [env.runId])
    }
  }

  private func sessionFlags(_ env: Fixture) throws -> (tainted: Bool, privateData: Bool) {
    try env.queue.read { db in
      let row = try #require(
        try Row.fetchOne(
          db,
          sql: "SELECT tainted, has_private_data FROM sessions WHERE id = ?",
          arguments: [env.sessionId]
        )
      )
      return (row["tainted"], row["has_private_data"])
    }
  }

  private func lastToolAudit(_ env: Fixture) throws -> Row {
    try env.queue.read { db in
      try #require(
        try Row.fetchOne(
          db,
          sql: """
            SELECT tool, args_redacted, result_size, decision
            FROM audit_events
            WHERE run_id = ? AND action = ?
            ORDER BY id DESC LIMIT 1
            """,
          arguments: [env.runId, AuditAction.toolCall.rawValue]
        )
      )
    }
  }

  @Test func executesRecordedArgsAndFillsTheObservation() async throws {
    // given
    let env = try makeSuspendedFixture()
    let executor = makeExecutor(
      env,
      tools: [RecordingWriteTool(toolName: "file_write", result: "Wrote 12 B to /w/plan.md.")]
    )

    // when
    let commit = await executor.executeApproved(
      approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
    )

    // then — the tool's real result lands in the placeholder and the run resumes
    #expect(commit == .committed)
    #expect(try messageContent(env) == "Wrote 12 B to /w/plan.md.")
    #expect(try runState(env) == RunState.running.rawValue)
  }

  @Test func awaitsAStallingToolToCompletionWithoutTheTimeoutAbandonRace() async throws {
    // given
    let env = try makeSuspendedFixture()
    let gate = ExecutionGate()
    let executor = makeExecutor(
      env,
      tools: [
        RecordingWriteTool(
          toolName: "file_write",
          result: "the gated write finished",
          gate: gate
        )
      ]
    )

    // when: the tool remains suspended until the test releases the signal
    let execution = Task {
      await executor.executeApproved(
        approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
      )
    }
    await gate.waitUntilStarted()
    await gate.release()
    let commit = await execution.value

    // then: approved execution awaits completion and records the truthful result
    #expect(commit == .committed)
    #expect(try messageContent(env) == "the gated write finished")
  }

  @Test func fullPayloadStatusProvenanceAndRedactedArgsReachTheFill() async throws {
    // given
    let env = try makeSuspendedFixture()
    let secret = "owner-secret-value"
    let rawArgs = #"{"code":"owner-secret-value"}"#
    let executor = makeExecutor(
      env,
      tools: [
        RecordingWriteTool(
          toolName: "execute_code",
          result: "exit 9",
          status: .error,
          ingestedUntrusted: true,
          readPrivateData: true
        )
      ],
      redactArguments: { arguments in
        arguments.replacingOccurrences(of: secret, with: "[REDACTED:secret-value]")
      }
    )

    // when
    let commit = await executor.executeApproved(
      approval(env, tool: "execute_code", argsJSON: rawArgs, target: "code_exec:sh:abcd")
    )

    // then
    #expect(commit == .committed)
    #expect(try messageContent(env) == "exit 9")
    #expect(try sessionFlags(env).tainted)
    #expect(try sessionFlags(env).privateData)
    let audit = try lastToolAudit(env)
    #expect(audit["tool"] == "execute_code")
    #expect(audit["decision"] == ToolObservationStatus.error.rawValue)
    let argsRedacted: String = audit["args_redacted"]
    #expect(argsRedacted == #"{"code":"[REDACTED:secret-value]"}"#)
    #expect(argsRedacted.contains(secret) == false)
  }

  @Test func stopDuringExecutionRetainsCompletedPayloadProvenance() async throws {
    // given
    let env = try makeSuspendedFixture()
    let gate = ExecutionGate()
    let executor = makeExecutor(
      env,
      tools: [
        RecordingWriteTool(
          toolName: "execute_code",
          result: "completed output",
          ingestedUntrusted: true,
          readPrivateData: true,
          gate: gate
        )
      ]
    )
    let execution = Task {
      await executor.executeApproved(
        approval(env, tool: "execute_code", argsJSON: "{}", target: "code_exec:sh:abcd")
      )
    }
    await gate.waitUntilStarted()

    // when: claim is already RUNNING; /stop wins before the fill
    _ = try env.runs.cancelActiveRun(
      sessionId: env.sessionId,
      reason: .cancelled,
      now: Date()
    )
    await gate.release()
    let commit = await execution.value

    // then
    #expect(commit == .committed)
    #expect(try runState(env) == RunState.cancelled.rawValue)
    #expect(try messageContent(env) == "completed output")
    #expect(try sessionFlags(env).tainted)
    #expect(try sessionFlags(env).privateData)
  }

  @Test func newDuringExecutionNeverRetaintsTheFreshWindow() async throws {
    // given
    let env = try makeSuspendedFixture()
    let gate = ExecutionGate()
    let executor = makeExecutor(
      env,
      tools: [
        RecordingWriteTool(
          toolName: "execute_code",
          result: "old-window output",
          ingestedUntrusted: true,
          readPrivateData: true,
          gate: gate
        )
      ]
    )
    let execution = Task {
      await executor.executeApproved(
        approval(env, tool: "execute_code", argsJSON: "{}", target: "code_exec:sh:abcd")
      )
    }
    await gate.waitUntilStarted()

    // when: /new supersedes/detaints after claim but before fill
    _ = try env.runs.supersedeSessionRuns(sessionId: env.sessionId, now: Date())
    await gate.release()
    let commit = await execution.value

    // then: old observation and audit are truthful; fresh-window flags remain clear
    #expect(commit == .committed)
    #expect(try runState(env) == RunState.superseded.rawValue)
    #expect(try messageContent(env) == "old-window output")
    #expect(try sessionFlags(env).tainted == false)
    #expect(try sessionFlags(env).privateData == false)
    #expect(try lastToolAudit(env)["tool"] == "execute_code")
  }

  @Test func memoryWriteFusesTheInsertAndIsExactlyOnce() async throws {
    // given — no tool is registered for memory_write: the executor rebuilds the item and routes
    // through the fused store method (D10), never a tool `execute`
    let env = try makeSuspendedFixture()
    let executor = makeExecutor(env, tools: [])
    let memoryApproval = approval(
      env,
      tool: "memory_write",
      argsJSON: #"{"kind":"project","text":"the plan shipped"}"#,
      target: "memory_item:project:abc123"
    )

    // when
    let first = await executor.executeApproved(memoryApproval)
    let second = await executor.executeApproved(memoryApproval)

    // then — one memory row, observation filled, and the duplicate is a no-op (§6.3)
    #expect(first == .committed)
    #expect(second == .ignored)
    let memoryCount = try await env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items")
    }
    #expect(memoryCount == 1)
    #expect(try messageContent(env)?.contains("project") == true)
  }

  @Test func aRunCancelledAfterApprovalNeverExecutesTheWrite() async throws {
    // given — the Approve callback won its CAS, then /stop drove the run terminal before the
    // waiter reached the executor (the §6.6 cancel race)
    let env = try makeSuspendedFixture()
    try await env.queue.write { db in
      _ = try RunStoreGRDB.transitionRun(db, runId: env.runId, event: .cancel, now: Date())
    }
    let probe = ExecutionProbe()
    let executor = makeExecutor(
      env,
      tools: [RecordingWriteTool(toolName: "file_write", result: "MUST NOT LAND", probe: probe)]
    )

    // when
    let commit = await executor.executeApproved(
      approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
    )

    // then — the tool body never ran, the run stays cancelled, and the placeholder is resolved
    // with the truthful not-run note instead of dangling
    #expect(commit == .runNotResumable)
    #expect(await probe.executed == false)
    #expect(try runState(env) == RunState.cancelled.rawValue)
    #expect(try messageContent(env) == ApprovedActionExecutor.notResumableObservationContent)
  }

  @Test func theRunIsClaimedRunningBeforeTheToolBodyExecutes() async throws {
    // given — a tool that reports the run row's live state from inside its own body
    let env = try makeSuspendedFixture()
    let executor = makeExecutor(
      env,
      tools: [RunStateReportingTool(queue: env.queue, runId: env.runId)]
    )

    // when
    let commit = await executor.executeApproved(
      approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
    )

    // then — the AWAITING→RUNNING claim committed BEFORE the external effect started, so a /stop
    // arriving from here on can only cancel a run that already owns its write
    #expect(commit == .committed)
    #expect(try messageContent(env) == RunState.running.rawValue)
  }

  @Test func aThrowingResultRecordSurfacesRecordFailedAfterTheToolRan() async throws {
    // given — the claim seam works (real store), but recording the executed result throws
    let env = try makeSuspendedFixture()
    let executor = makeExecutor(
      env,
      tools: [RecordingWriteTool(toolName: "file_write", result: "Wrote 12 B to /w/plan.md.")],
      runs: FillFailingRuns(base: env.runs)
    )

    // when
    let commit = await executor.executeApproved(
      approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
    )

    // then — DISTINCT from storeFailed: the action ran, so the waiter must not promise a retry;
    // the run stays claimed RUNNING for the boot orphan-fail sweep
    #expect(commit == .recordFailed)
    #expect(try runState(env) == RunState.running.rawValue)
    #expect(try messageContent(env) == "awaiting owner approval")
  }

  @Test func aThrowingObservationCommitSurfacesStoreFailedNotIgnored() async throws {
    // given — the store throws at the commit seam (DiskFullRuns); the durable DB is untouched
    let env = try makeSuspendedFixture()
    let executor = makeExecutor(
      env,
      tools: [RecordingWriteTool(toolName: "file_write", result: "Wrote 12 B to /w/plan.md.")],
      runs: DiskFullRuns()
    )

    // when
    let commit = await executor.executeApproved(
      approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
    )

    // then — a store failure is DISTINCT from a duplicate resume: the waiter must not read it as
    // "already resumed"; the run stays AWAITING_APPROVAL for the §6.5 boot crash-window recovery
    #expect(commit == .storeFailed)
    #expect(try runState(env) == RunState.awaitingApproval.rawValue)
    #expect(try messageContent(env) == "awaiting owner approval")
  }

  @Test func aThrowingMemoryWriteCommitSurfacesStoreFailedNotIgnored() async throws {
    // given — the fused memory_write commit throws at the store seam
    let env = try makeSuspendedFixture()
    let executor = makeExecutor(env, tools: [], runs: DiskFullRuns())

    // when
    let commit = await executor.executeApproved(
      approval(
        env,
        tool: "memory_write",
        argsJSON: #"{"kind":"project","text":"the plan shipped"}"#,
        target: "memory_item:project:abc123"
      )
    )

    // then — same contract as the generic write: distinct failure signal, nothing committed
    #expect(commit == .storeFailed)
    #expect(try runState(env) == RunState.awaitingApproval.rawValue)
    let memoryCount = try await env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items")
    }
    #expect(memoryCount == 0)
  }

  /// A `RunStore` whose pre-execution claim works (delegated to the real store) but whose result
  /// record throws — isolates the post-execution half of the crash window.
  private struct FillFailingRuns: RunStore {
    let base: RunStoreGRDB

    func claimApprovedExecution(
      runId: Int64,
      observationMessageId: Int64,
      notResumableObservationContent: String,
      now: Date
    ) throws(StoreError) -> ApprovedExecutionClaim {
      try base.claimApprovedExecution(
        runId: runId,
        observationMessageId: observationMessageId,
        notResumableObservationContent: notResumableObservationContent,
        now: now
      )
    }

    func fillClaimedObservation(
      runId: Int64,
      observationMessageId: Int64,
      fill: ClaimedObservationFill
    ) throws(StoreError) {
      throw StoreError.diskFull
    }

    func applyApprovedMemoryWrite(  // swiftlint:disable:this function_parameter_count
      runId: Int64,
      observationMessageId: Int64,
      item: NewMemoryItem,
      observationContent: String,
      audit: ApprovedExecutionAudit,
      notResumableObservationContent: String,
      now: Date
    ) throws(StoreError) -> ApprovedExecutionClaim {
      throw StoreError.diskFull
    }

    func pickUp(runId: Int64, policyVersion: String?, now: Date) throws(StoreError) -> RunOrigin? {
      nil
    }
    func commitAssistantTurn(
      _ turn: AssistantTurn,
      now: Date
    ) throws(StoreError) -> RunCommitResult {
      .ignored
    }
    func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws(StoreError) -> RunCommitResult {
      .ignored
    }
    func failRun(runId: Int64, now: Date) throws(StoreError) {}
    func cancelActiveRun(
      sessionId: Int64,
      reason: CancelReason,
      now: Date
    ) throws(StoreError) -> Int64? {
      nil
    }
    func supersedeSessionRuns(sessionId: Int64, now: Date) throws(StoreError) -> [Int64] { [] }
    func reconcileRunsAtBoot(
      now: Date,
      degradationText: String,
      heartbeatNoticeChatId: Int64?
    ) throws(StoreError) -> [DegradationReply] { [] }
    func runsHealth(now: Date) throws(StoreError) -> RunsHealth {
      RunsHealth(
        inFlight: 0,
        oldestRunAgeSeconds: nil,
        lastFailedAt: nil,
        lastSuccessAt: nil,
        consecutiveFailures: 0
      )
    }
    func commitSuspendedTurn(
      runId: Int64,
      sessionId: Int64,
      commit: SuspendedTurnCommit,
      now: Date
    ) throws(StoreError) -> SuspendedCommitReceipt {
      throw StoreError.unexpected("unused in this fixture")
    }
    func settleClaimedApprovalAtBoot(
      runId: Int64,
      observationMessageId: Int64,
      observationContent: String,
      noticeChatId: Int64,
      noticeText: String,
      now: Date
    ) throws(StoreError) -> ClaimedApprovalBootOutcome {
      throw StoreError.unexpected("unused in this fixture")
    }
    func resumeUsage(runId: Int64) throws(StoreError) -> ResumeUsage {
      throw StoreError.unexpected("unused in this fixture")
    }
    func runOrigin(runId: Int64) throws(StoreError) -> RunOrigin? { nil }
    func failRunStalePolicy(
      runId: Int64,
      sessionId: Int64,
      observationMessageId: Int64,
      observationContent: String,
      now: Date
    ) throws(StoreError) -> Bool { false }
    func resolveDeniedObservation(
      runId: Int64,
      observationMessageId: Int64,
      content: String,
      cancel: CancelReason?,
      now: Date
    ) throws(StoreError) -> RunCommitResult { .ignored }
  }

  @Test func aMissingToolStillResumesWithAnErrorObservation() async throws {
    // given — a recorded action whose tool is no longer registered
    let env = try makeSuspendedFixture()
    let executor = makeExecutor(env, tools: [])

    // when
    let commit = await executor.executeApproved(
      approval(env, tool: "vanished_tool", argsJSON: "{}")
    )

    // then — the run must not hang: it resumes with a truthful failure observation
    #expect(commit == .committed)
    #expect(try runState(env) == RunState.running.rawValue)
    #expect(try messageContent(env)?.isEmpty == false)
  }
}
