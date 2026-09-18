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
    let dispatcher = ScriptedDispatcher { call, context in
      entered.open()
      await release.wait()
      return okOutcome()(call, context)
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
  }
}
