import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import ClawTools
import ClawWorkspace
import Foundation
import GRDB
import Testing

@testable import ClawGateway

/// A minimal ask-tier tool: resolves a fixed contained target and executes trivially. Exists only to
/// drive the real gate → `TurnResult.suspended` in Phase 2 (no production tool declares `ask` yet).
struct ScriptedAskTool: Tool {
  var definition: ToolDefinition {
    ToolDefinition(
      name: "scripted_write",
      description: "test-only ask-tier tool",
      parameters: .object(["type": .string("object")]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .ask
    )
  }
  var timeout: Duration { .seconds(5) }

  func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    .resolved("/workspace/notes/plan.md")
  }
  func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    ToolPayload(content: "wrote it", status: .ok, ingestedUntrusted: false)
  }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct SuspendLaneHoldTests {
  private func approvals(_ pool: DatabasePool) throws -> [Row] {
    try pool.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM approvals ORDER BY id")
    }
  }

  private func runState(_ path: String, _ runId: Int64) throws -> String? {
    let pool = try ClawDatabase.makePool(path: path)
    return try pool.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
    }
  }

  @Test func proposalSuspendsHoldsTheLaneAndStaysAssemblyVisible() async throws {
    // given — a shared coordinator so the test can release the held lane; the ask-tier tool
    // registered as an extra tool; two scripts (the suspending proposal, then the plain message)
    let coordinator = ApprovalCoordinator()
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([
            ToolCall(id: "w1", name: "scripted_write", argumentsJSON: "{}")
          ])
        ],
        [okResponse(content: "second turn done")],
      ],
      httpResponses: [:],
      coordinator: coordinator,
      extraTools: [ScriptedAskTool()]
    )

    // when — the proposal suspends the run to a persisted checkpoint
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write the plan"))
    var notifications = harness.outboxSignal.notifications.makeAsyncIterator()
    _ = await notifications.next()
    let approval = try #require(try approvals(harness.readPool).first)
    let approvalId: Int64 = approval["id"]
    let runId: Int64 = approval["run_id"]

    // then — persisted PENDING checkpoint + AWAITING run + prompt chunk with a keyboard
    #expect(approval["state"] == ApprovalState.pending.rawValue)
    #expect(approval["tool"] == "scripted_write")
    #expect(try runState(harness.databasePath, runId) == RunState.awaitingApproval.rawValue)
    let promptRow = try harness.stores.outbox.pendingOutbound().first
    #expect(promptRow != nil)
    let markup = try await ClawDatabase.makePool(path: harness.databasePath).read { db in
      try String.fetchOne(
        db,
        sql: "SELECT reply_markup FROM outbound_deliveries WHERE approval_id = ?",
        arguments: [approvalId]
      )
    }
    #expect(markup?.isEmpty == false)

    // when — a plain message arrives while the lane is HELD by the suspended turn
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "are you there?"))

    // then — it must NOT have produced a reply yet (FIFO behind the held lane); the suspended run
    // counts toward in-flight (Task 05 widened `runsHealth` to include AWAITING_APPROVAL).
    await Task.yield()
    #expect(try harness.stores.runs.runsHealth(now: Date()).inFlight >= 1)

    // when — release the lane; the queued plain message now runs to completion. The reply lands in
    // the durable OUTBOX — this harness wires no `OutboxDispatcher`, so nothing is sent over the
    // `RecordingTransport`; existing SC3 assertions read `stores.outbox.pendingOutbound()` too.
    await coordinator.signal(approvalId: approvalId, .denied(.cancelled))
    while true {
      let payloads = try harness.stores.outbox.pendingOutbound().map(\.payload)
      if payloads.contains(where: { payload in
        payload.contains("second turn done")
      }) {
        break
      }
      guard await notifications.next() != nil else {
        Issue.record("outbox notifications ended before the queued reply committed")
        return
      }
    }

    // then — the parked exchange is still assembly-visible: the anchor + its (placeholder) tool row
    // survive `HistoryHygiene` even with the interleaved plain message (§5.3 contiguity). Asserted
    // through the PUBLIC assembler (`assemble` runs `HistoryHygiene`), since the grouping helper
    // `historyGroups`/`HistoryGroup` is `private` to `ContextBuilder.swift` and not test-reachable.
    let sessionId: Int64 = approval["session_id"]
    let contextBuilder = ContextBuilder(
      systemPrompt: SystemPrompt.minimal,
      workspace: FileSystemWorkspace(root: harness.workspaceRoot),
      memoryStore: harness.stores.memory,
      retriever: harness.stores.retriever,
      budget: .default
    )
    let lastMessageId = try await ClawDatabase.makePool(path: harness.databasePath).read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT MAX(id) FROM messages WHERE session_id = ?",
        arguments: [sessionId]
      ) ?? 0
    }
    let snapshot = try harness.stores.sessionMessages.loadContextSnapshot(
      sessionId: sessionId,
      throughMessageId: lastMessageId,
      limit: 50
    )
    let assembled = try contextBuilder.assemble(
      snapshot: snapshot,
      sessionId: sessionId,
      origin: .interactive
    )
    #expect(assembled.messages.contains { $0.role == .assistant && $0.toolCalls.isEmpty == false })
    #expect(assembled.messages.contains { $0.role == .tool })
  }
}
