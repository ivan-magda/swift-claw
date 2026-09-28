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
    #expect(outcome.result == .budgetStopped(cap: "per-run spend"))
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
  func carriedOverRoundsAtTheTurnCapStillSendOneRound() async throws {
    // given — the run suspended in its last allowed round, so the carried rounds already equal
    // the turn cap when the approved continuation resumes
    let provider = StubProvider(.respond(okResponse(content: "resumed")))
    let runtime = makeRuntime(provider: provider)
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

    // then — the segment still sends one round rather than building an empty round range
    let completed = try requireCompleted(outcome.result)
    #expect(completed.content == "resumed")
  }
}
