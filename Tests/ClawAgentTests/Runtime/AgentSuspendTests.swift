import ClawCore
import Foundation
import Testing

@testable import ClawAgent

/// §5.2 durable suspend semantics: the FIRST ask-tier proposal in a tool-call batch records its
/// action and parks the run (`TurnResult.suspended`); earlier calls execute normally and further
/// gated calls observe "an approval is already pending" instead of parking a second time. Also
/// pins `TurnOutcome.hadPrivateData = assemblyPrivateData ∪ runPrivateData` (D6).
@Suite struct AgentSuspendTests {
  // MARK: - Fixtures

  private func recorded(tool: String, target: String = "/ws/notes/plan.md") -> RecordedToolAction {
    RecordedToolAction(
      tool: tool,
      canonicalArgsJSON: #"{"content":"hello","path":"notes/plan.md"}"#,
      argsHash: "abc123",
      canonicalTarget: target,
      reason: .askTier,
      presentation: ToolApprovalPresentation(
        blastRadius: "create, 5 B",
        contentPreview: "hello",
        warnings: []
      )
    )
  }

  /// The gate returned `.requireApproval`: the tool has NOT executed. Its observation is a
  /// placeholder the loop DISCARDS — the real placeholder row rides the suspend commit (§5.3).
  private func requireApprovalOutcome(call: ToolCall, tool: String) -> ToolDispatchOutcome {
    ToolDispatchOutcome(
      observation: ToolObservation(
        callId: call.id,
        toolName: call.name,
        content: "awaiting owner approval",
        status: .ok,
        ingestedUntrusted: false
      ),
      argsRedacted: call.argumentsJSON,
      requiresApproval: recorded(tool: tool)
    )
  }

  private func blockedOutcome(call: ToolCall) -> ToolDispatchOutcome {
    ToolDispatchOutcome(
      observation: ToolObservation(
        callId: call.id,
        toolName: call.name,
        content: "blocked: an approval is already pending",
        status: .blockedPendingApproval,
        ingestedUntrusted: false
      ),
      argsRedacted: call.argumentsJSON
    )
  }

  private func okOutcome(call: ToolCall, readPrivateData: Bool = false) -> ToolDispatchOutcome {
    ToolDispatchOutcome(
      observation: ToolObservation(
        callId: call.id,
        toolName: call.name,
        content: "ok",
        status: .ok,
        ingestedUntrusted: false,
        readPrivateData: readPrivateData
      ),
      argsRedacted: call.argumentsJSON
    )
  }

  // MARK: - Mid-batch suspend

  @Test func firstAskTierProposalSuspendsCarryingThePendingAction() async throws {
    // given — one batch: a safe read that executes, then an ask-tier file_write that parks
    let readCall = ToolCall(id: "r1", name: "file_read", argumentsJSON: #"{"path":"a.md"}"#)
    let writeCall = ToolCall(
      id: "w1",
      name: "file_write",
      argumentsJSON: #"{"path":"notes/plan.md","content":"hello"}"#
    )
    let dispatcher = ScriptedDispatcher { call, _ in
      call.name == "file_read"
        ? self.okOutcome(call: call)
        : self.requireApprovalOutcome(call: call, tool: "file_write")
    }
    let provider = SequenceProvider([toolCallResponse([readCall, writeCall])])
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 1,
      chatId: 7,
      buildResult: makeBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the run parked on the FIRST ask-tier proposal, carrying its recorded action
    guard case .suspended(let pending, _) = outcome.result else {
      Issue.record("expected .suspended, got \(outcome.result)")
      return
    }
    #expect(pending.toolCallId == "w1")
    #expect(pending.recorded.tool == "file_write")
    #expect(pending.recorded.reason == .askTier)
    #expect(pending.recorded.canonicalTarget == "/ws/notes/plan.md")

    // and — the earlier safe call's observation persists; the parked call's does NOT (its
    // placeholder row is reserved at the suspend commit, §5.3)
    let exchange = try #require(outcome.exchanges.first)
    #expect(exchange.toolCalls.map(\.id) == ["r1", "w1"])
    #expect(exchange.observations.map(\.callId) == ["r1"])
  }

  @Test func furtherGatedCallInTheSameBatchIsBlockedNotASecondSuspension() async throws {
    // given — two ask-tier proposals in one batch
    let firstCall = ToolCall(
      id: "w1",
      name: "file_write",
      argumentsJSON: #"{"path":"notes/plan.md","content":"hello"}"#
    )
    let secondCall = ToolCall(
      id: "w2",
      name: "memory_write",
      argumentsJSON: #"{"text":"remember"}"#
    )
    let dispatcher = ScriptedDispatcher { call, context in
      // The durable pending action feeds the gate's approvalAlreadyPending flag: the first call
      // parks, every later call in the batch is blocked-observation only (§5.2).
      context.approvalAlreadyPending
        ? self.blockedOutcome(call: call)
        : self.requireApprovalOutcome(call: call, tool: call.name)
    }
    let provider = SequenceProvider([toolCallResponse([firstCall, secondCall])])
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)

    // when
    let outcome = try await runtime.runTurn(
      runId: 2,
      sessionId: 2,
      chatId: 7,
      buildResult: makeBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — exactly ONE park (the first); the second is a blocked observation
    guard case .suspended(let pending, _) = outcome.result else {
      Issue.record("expected .suspended, got \(outcome.result)")
      return
    }
    #expect(pending.toolCallId == "w1")
    #expect(pending.recorded.tool == "file_write")

    let exchange = try #require(outcome.exchanges.first)
    #expect(exchange.observations.map(\.callId) == ["w2"])
    #expect(exchange.observations.first?.status == .blockedPendingApproval)

    // and — the second call's dispatch context saw the pending flag set by the first
    let records = await dispatcher.records
    #expect(records.map(\.context.approvalAlreadyPending) == [false, true])
  }

  // MARK: - hadPrivateData (D6)

  @Test func hadPrivateDataReflectsTheAssemblyFlag() async throws {
    // given — context assembled a USER/MEMORY section (assemblyPrivateData), no tools
    let provider = StubProvider(.respond(okResponse(content: "done")))
    let runtime = makeRuntime(provider: provider)

    // when
    let outcome = try await runtime.runTurn(
      runId: 3,
      sessionId: 3,
      chatId: 7,
      buildResult: makeBuildResult(hasPrivateDataAccess: true),
      sessionTainted: false,
      sessionHasPrivateData: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    #expect(outcome.hadPrivateData)
  }

  @Test func hadPrivateDataReflectsARunLocalPrivateRead() async throws {
    // given — assembly touched no private data, but an executed tool read it THIS run
    let readCall = ToolCall(id: "p1", name: "file_read", argumentsJSON: #"{"path":"MEMORY.md"}"#)
    let dispatcher = ScriptedDispatcher { call, _ in
      self.okOutcome(call: call, readPrivateData: true)
    }
    let provider = SequenceProvider([
      toolCallResponse([readCall]),
      okResponse(content: "done"),
    ])
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)

    // when
    let outcome = try await runtime.runTurn(
      runId: 4,
      sessionId: 4,
      chatId: 7,
      buildResult: makeBuildResult(hasPrivateDataAccess: false),
      sessionTainted: false,
      sessionHasPrivateData: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the union catches the run-local read even when assembly was clean
    #expect(outcome.hadPrivateData)
  }
}
