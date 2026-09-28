import ClawCore
import ClawTestSupport
import Testing

@testable import ClawAgent

@Suite
struct AgentRuntimeCarryOverTests {
  @Test
  func carriedOverSpendStopsBeforeAnyProviderCall() async throws {
    // given — a run that already spent its entire per-run USD budget before it suspended; the
    // resume must inherit that spend so a suspend cycle can't reset the cap (§6.3 no cap evasion)
    let provider = StubProvider(.respond(okResponse(content: "should never send")))
    let runtime = makeRuntime(provider: provider)
    let carryOver = ResumeUsage(
      rounds: 1,
      toolCalls: 0,
      tokens: 0,
      costUSD: RunBudget.default.perRunUSD + 1
    )

    // when
    let outcome = try await runtime.runTurn(
      makeTurnRequest(
        runID: 1,
        sessionID: 1,
        chatID: 7,
        context: makeBuildResult(),
        carryOver: carryOver
      )
    )

    // then — the per-run spend cap trips on the carried total; the provider is never reached
    #expect(outcome.result == .budgetStopped(cap: BudgetGate.perRunSpendCap))
    #expect(await provider.calls == 0)
  }

  @Test
  func nilCarryOverLeavesTheRunFreeToComplete() async throws {
    // given — the identical setup WITHOUT carry-over completes, proving the stop above came from
    // the seeded counter and not the base budget
    let provider = StubProvider(.respond(okResponse(content: "hi")))
    let runtime = makeRuntime(provider: provider)

    // when
    let outcome = try await runtime.runTurn(
      makeTurnRequest(runID: 1, sessionID: 1, chatID: 7, context: makeBuildResult())
    )

    // then
    let completed = try requireCompleted(outcome.result)
    #expect(completed.content == "hi")
  }

  @Test
  func carriedOverRoundsAtTheTurnCapAllowExactlyOneRound() async throws {
    // given — the carried rounds already equal the turn cap when the approved continuation
    // resumes, and the model keeps proposing tools
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal(id: "c1")]),
      toolCallResponse([fetchProposal(id: "c2")]),
    ])
    let runtime = makeRuntime(
      provider: provider,
      toolDispatcher: ScriptedDispatcher(respond: okOutcome())
    )
    let carryOver = ResumeUsage(
      rounds: RunBudget.default.maxTurns,
      toolCalls: 0,
      tokens: 0,
      costUSD: 0
    )

    // when
    let outcome = try await runtime.runTurn(
      makeTurnRequest(
        runID: 1,
        sessionID: 1,
        chatID: 7,
        context: makeBuildResult(),
        carryOver: carryOver
      )
    )

    // then — one round, rather than an empty round range or a fresh round budget
    #expect(outcome.result == .budgetStopped(cap: BudgetGate.perRunTurnCap))
    #expect(await provider.requests.count == 1)
  }

  @Test
  func carriedOverToolCallsCountTowardTheToolCallCap() async throws {
    // given — the carried tool calls already reach the cap, and the resumed round proposes another
    let provider = SequenceProvider([toolCallResponse([fetchProposal(id: "c1")])])
    let dispatcher = ScriptedDispatcher(respond: okOutcome())
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)
    let carryOver = ResumeUsage(
      rounds: 1,
      toolCalls: RunBudget.default.maxToolCalls,
      tokens: 0,
      costUSD: 0
    )

    // when
    let outcome = try await runtime.runTurn(
      makeTurnRequest(
        runID: 1,
        sessionID: 1,
        chatID: 7,
        context: makeBuildResult(),
        carryOver: carryOver
      )
    )

    // then — the proposal is the call past the cap, so it never reaches the dispatcher
    #expect(outcome.result == .budgetStopped(cap: BudgetGate.perRunToolCallCap))
    #expect(await dispatcher.records.isEmpty)
  }
}
