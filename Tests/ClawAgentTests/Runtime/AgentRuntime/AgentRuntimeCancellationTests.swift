import ClawTestSupport
import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite
struct AgentRuntimeCancellationTests {
  @Test
  func cancellationDuringAToolStopsTheRemainingBatch() async throws {
    // given
    let entered = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let first = fetchProposal(id: "first")
    let second = fetchProposal(id: "second")
    let provider = SequenceProvider([toolCallResponse([first, second]), okResponse()])
    let completedContent = "The first tool completed before cancellation was observed."
    let dispatcher = ScriptedDispatcher { call, context in
      entered.open()
      await release.wait()
      return okOutcome(content: completedContent)(call, context)
    }
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)
    let turn = Task {
      try await runtime.runTurn(
        runID: 1,
        sessionID: 1,
        chatID: 1,
        buildResult: makeBuildResult(),
        sessionTainted: false,
        hasPinnedLessons: false,
        sessionHasPrivateData: false,
        todayTokens: 0,
        todayUSD: 0
      )
    }
    defer { turn.cancel() }

    // when
    let started = await entered.waitUntilOpen()
    turn.cancel()
    let outcome = try await turn.value

    // then
    #expect(started)
    #expect(await dispatcher.records.map(\.call.id) == [first.id])
    #expect(outcome.attemptDiagnostics.failureCause == .processInterruption)
    let exchange = try #require(outcome.exchanges.first)
    #expect(exchange.toolCalls == [first, second])
    #expect(exchange.observations.count == exchange.toolCalls.count)
    let completed = try #require(
      exchange.observations.first {
        $0.callID == first.id
      }
    )
    #expect(completed.content == completedContent)
    #expect(completed.status == .ok)
    let unstarted = try #require(
      exchange.observations.first {
        $0.callID == second.id
      }
    )
    #expect(unstarted.status == .error)
    #expect(unstarted.ingestedUntrusted == false)
  }

  @Test
  func cancellationDuringTheLastApprovalProposalDoesNotSuspend() async throws {
    // given
    let entered = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let call = ToolCall(
      id: "pending",
      name: "file_write",
      argumentsJSON: #"{"path":"notes/a.md","content":"hello"}"#
    )
    let action = RecordedToolAction(
      tool: call.name,
      canonicalArgsJSON: call.argumentsJSON,
      argsHash: "fixture-hash",
      canonicalTarget: "/ws/notes/a.md",
      reason: .askTier,
      presentation: ToolApprovalPresentation(
        blastRadius: "create",
        contentPreview: "hello",
        warnings: []
      )
    )
    let dispatcher = ScriptedDispatcher { call, context in
      entered.open()
      await release.wait()
      return ToolDispatchOutcome(
        observation: okOutcome(ingestedUntrusted: false)(call, context).observation,
        argsRedacted: call.argumentsJSON,
        requiresApproval: action
      )
    }
    let runtime = makeRuntime(
      provider: SequenceProvider([toolCallResponse([call])]),
      toolDispatcher: dispatcher
    )
    let turn = Task {
      try await runtime.runTurn(
        runID: 1,
        sessionID: 1,
        chatID: 1,
        buildResult: makeBuildResult(),
        sessionTainted: false,
        hasPinnedLessons: false,
        sessionHasPrivateData: false,
        todayTokens: 0,
        todayUSD: 0
      )
    }
    defer { turn.cancel() }

    // when
    let started = await entered.waitUntilOpen()
    turn.cancel()
    let outcome = try await turn.value

    // then
    #expect(started)
    _ = try requireDegraded(outcome.result)
    #expect(outcome.attemptDiagnostics.failureCause == .processInterruption)
    let exchange = try #require(outcome.exchanges.first)
    #expect(exchange.toolCalls == [call])
    let observation = try #require(exchange.observations.first)
    #expect(observation.callID == call.id)
    #expect(observation.status == .error)
  }
}
