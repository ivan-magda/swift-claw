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

  /// A ClawCore `Tool` double that records execution and can stall past its own declared timeout —
  /// the executor must still await it to completion (§6.6, never the read-tool abandon race).
  private struct RecordingWriteTool: Tool {
    let toolName: String
    let result: String
    let status: ToolObservationStatus
    let stallFor: Duration?
    let probe: ExecutionProbe?

    init(
      toolName: String,
      result: String,
      status: ToolObservationStatus = .ok,
      stallFor: Duration? = nil,
      probe: ExecutionProbe? = nil
    ) {
      self.toolName = toolName
      self.result = result
      self.status = status
      self.stallFor = stallFor
      self.probe = probe
    }

    var definition: ToolDefinition {
      ToolDefinition(
        name: toolName,
        description: "stub",
        parameters: .object(["type": .string("object")]),
        egressClass: .none,
        riskLevel: .ask
      )
    }

    var timeout: Duration { .milliseconds(1) }

    func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

    func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
      await probe?.mark()
      if let stallFor {
        try? await Task.sleep(for: stallFor)
      }
      return ToolPayload(content: result, status: status, ingestedUntrusted: false)
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
      return ToolPayload(content: state ?? "absent", status: .ok, ingestedUntrusted: false)
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
    runs: (any RunStore)? = nil
  ) -> ApprovedActionExecutor {
    ApprovedActionExecutor(
      tools: Dictionary(uniqueKeysWithValues: tools.map { ($0.definition.name, $0) }),
      runs: runs ?? env.runs,
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

  @Test func executesRecordedArgsAndFillsTheObservation() async throws {
    // given
    let env = try makeSuspendedFixture()
    let executor = makeExecutor(
      env,
      tools: [RecordingWriteTool(toolName: "file_write", result: "Wrote 12 B to /w/plan.md.")]
    )

    // when
    let outcome = await executor.executeApproved(
      approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
    )

    // then — the tool's real result lands in the placeholder and the run resumes
    #expect(outcome.commit == .committed)
    #expect(outcome.observationContent == "Wrote 12 B to /w/plan.md.")
    #expect(try messageContent(env) == "Wrote 12 B to /w/plan.md.")
    #expect(try runState(env) == RunState.running.rawValue)
  }

  @Test func awaitsAStallingToolToCompletionWithoutTheTimeoutAbandonRace() async throws {
    // given — the tool stalls 20ms past its own 1ms declared timeout; the executor must NOT abandon
    let env = try makeSuspendedFixture()
    let executor = makeExecutor(
      env,
      tools: [
        RecordingWriteTool(
          toolName: "file_write",
          result: "the slow write finished",
          stallFor: .milliseconds(20)
        )
      ]
    )

    // when
    let outcome = await executor.executeApproved(
      approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
    )

    // then — the observation is truthful: the completed result, never a "timed out but maybe applied"
    #expect(outcome.observationContent == "the slow write finished")
    #expect(try messageContent(env) == "the slow write finished")
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
    #expect(first.commit == .committed)
    #expect(second.commit == .ignored)
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
    let outcome = await executor.executeApproved(
      approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
    )

    // then — the tool body never ran, the run stays cancelled, and the placeholder is resolved
    // with the truthful not-run note instead of dangling
    #expect(outcome.commit == .runNotResumable)
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
    let outcome = await executor.executeApproved(
      approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
    )

    // then — the AWAITING→RUNNING claim committed BEFORE the external effect started, so a /stop
    // arriving from here on can only cancel a run that already owns its write
    #expect(outcome.commit == .committed)
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
    let outcome = await executor.executeApproved(
      approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
    )

    // then — DISTINCT from storeFailed: the action ran, so the waiter must not promise a retry;
    // the run stays claimed RUNNING for the boot orphan-fail sweep
    #expect(outcome.commit == .recordFailed)
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
    let outcome = await executor.executeApproved(
      approval(env, tool: "file_write", argsJSON: #"{"path":"plan.md"}"#)
    )

    // then — a store failure is DISTINCT from a duplicate resume: the waiter must not read it as
    // "already resumed"; the run stays AWAITING_APPROVAL for the §6.5 boot crash-window recovery
    #expect(outcome.commit == .storeFailed)
    #expect(try runState(env) == RunState.awaitingApproval.rawValue)
    #expect(try messageContent(env) == "awaiting owner approval")
  }

  @Test func aThrowingMemoryWriteCommitSurfacesStoreFailedNotIgnored() async throws {
    // given — the fused memory_write commit throws at the store seam
    let env = try makeSuspendedFixture()
    let executor = makeExecutor(env, tools: [], runs: DiskFullRuns())

    // when
    let outcome = await executor.executeApproved(
      approval(
        env,
        tool: "memory_write",
        argsJSON: #"{"kind":"project","text":"the plan shipped"}"#,
        target: "memory_item:project:abc123"
      )
    )

    // then — same contract as the generic write: distinct failure signal, nothing committed
    #expect(outcome.commit == .storeFailed)
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
    ) throws -> ApprovedExecutionClaim {
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
      content: String
    ) throws {
      throw StoreError.diskFull
    }

    func applyApprovedMemoryWrite(
      runId: Int64,
      observationMessageId: Int64,
      item: NewMemoryItem,
      observationContent: String,
      notResumableObservationContent: String,
      now: Date
    ) throws -> ApprovedExecutionClaim {
      throw StoreError.diskFull
    }

    func pickUp(runId: Int64, policyVersion: String?, now: Date) throws -> RunOrigin? { nil }
    func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws -> RunCommitResult {
      .ignored
    }
    func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws -> RunCommitResult {
      .ignored
    }
    func failRun(runId: Int64, now: Date) throws {}
    func cancelActiveRun(sessionId: Int64, reason: CancelReason, now: Date) throws -> Int64? {
      nil
    }
    func supersedeSessionRuns(sessionId: Int64, now: Date) throws -> [Int64] { [] }
    func reconcileRunsAtBoot(
      now: Date,
      degradationText: String,
      heartbeatNoticeChatId: Int64?
    ) throws -> [DegradationReply] { [] }
    func runsHealth(now: Date) throws -> RunsHealth {
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
    ) throws -> SuspendedCommitReceipt {
      throw StoreError.unexpected("unused in this fixture")
    }
    func settleClaimedApprovalAtBoot(
      runId: Int64,
      observationMessageId: Int64,
      observationContent: String,
      noticeChatId: Int64,
      noticeText: String,
      now: Date
    ) throws -> ClaimedApprovalBootOutcome {
      throw StoreError.unexpected("unused in this fixture")
    }
    func resumeUsage(runId: Int64) throws -> ResumeUsage {
      throw StoreError.unexpected("unused in this fixture")
    }
    func runOrigin(runId: Int64) throws -> RunOrigin? { nil }
    func failRunStalePolicy(runId: Int64, sessionId: Int64, now: Date) throws -> Bool { false }
    func resolveDeniedObservation(
      runId: Int64,
      observationMessageId: Int64,
      content: String,
      cancel: CancelReason?,
      now: Date
    ) throws -> RunCommitResult { .ignored }
  }

  @Test func aMissingToolStillResumesWithAnErrorObservation() async throws {
    // given — a recorded action whose tool is no longer registered
    let env = try makeSuspendedFixture()
    let executor = makeExecutor(env, tools: [])

    // when
    let outcome = await executor.executeApproved(
      approval(env, tool: "vanished_tool", argsJSON: "{}")
    )

    // then — the run must not hang: it resumes with a truthful failure observation
    #expect(outcome.commit == .committed)
    #expect(try runState(env) == RunState.running.rawValue)
    #expect(try messageContent(env)?.isEmpty == false)
  }
}
