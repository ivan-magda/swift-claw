import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite struct AgentLoopTests {
  private func run(
    _ runtime: AgentRuntime,
    buildResult: BuildResult = makeBuildResult(),
    sessionTainted: Bool = false,
    origin: RunOrigin = .interactive,
    proactiveTodayUSD: Double = 0
  ) async throws -> TurnOutcome {
    try await runtime.runTurn(
      runId: 1,
      sessionId: 1,
      chatId: 1,
      buildResult: buildResult,
      sessionTainted: sessionTainted,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0,
      origin: origin,
      proactiveTodayUSD: proactiveTodayUSD
    )
  }

  @Test func proactiveRunStopsAtTheProactiveCapBeforeAnyProviderCall() async throws {
    // given — the proactive pool is exhausted; the global pool is not
    let provider = SequenceProvider([okResponse()])
    let runtime = makeRuntime(provider: provider)

    // when
    let outcome = try await run(runtime, origin: .scheduled, proactiveTodayUSD: 2.0)

    // then — denied offline, before the provider is reached
    #expect(outcome.result == .budgetStopped(cap: "proactive per-day spend"))
    #expect(await provider.requests.isEmpty)
  }

  @Test func interactiveRunIgnoresProactiveSpend() async throws {
    // given — the same exhausted proactive pool
    let provider = SequenceProvider([okResponse(content: "still on")])
    let runtime = makeRuntime(provider: provider)

    // when
    let outcome = try await run(runtime, origin: .interactive, proactiveTodayUSD: 2.0)

    // then — interactive runs never consult the nested pool (S3)
    let completed = try requireCompleted(outcome.result)
    #expect(completed.content == "still on")
  }

  @Test func toollessTurnIsOneRoundTripCompleted() async throws {
    // given
    let provider = SequenceProvider([okResponse(content: "plain answer")])
    let runtime = makeRuntime(provider: provider)

    // when
    let outcome = try await run(runtime)

    // then
    let completed = try requireCompleted(outcome.result)
    #expect(completed.content == "plain answer")
    #expect(outcome.exchanges.isEmpty)
    #expect(outcome.ingestedUntrusted == false)
    #expect(await provider.requests.count == 1)
  }

  @Test func toolRoundTripFeedsObservationBackAndCompletes() async throws {
    // given — round trip 1 proposes a fetch; round trip 2 answers
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal()], content: "let me check"),
      okResponse(content: "the page says hello"),
    ])
    let dispatcher = ScriptedDispatcher(respond: okOutcome(content: "page text"))
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)

    // when
    let outcome = try await run(runtime)

    // then — completed; the exchange is recorded; taint flag set
    let completed = try requireCompleted(outcome.result)
    #expect(completed.content == "the page says hello")
    #expect(outcome.exchanges.count == 1)
    #expect(outcome.exchanges[0].assistantContent == "let me check")
    #expect(outcome.exchanges[0].observations[0].content == "page text")  // RAW in the exchange
    #expect(outcome.ingestedUntrusted)

    // and the second request carried the anchor + the FENCED observation (§6.5/§12)
    let secondRequest = await provider.requests[1]
    let anchor = secondRequest.messages[secondRequest.messages.count - 2]
    #expect(anchor.role == .assistant)
    #expect(anchor.toolCalls.map(\.id) == ["c1"])
    let observationMessage = secondRequest.messages[secondRequest.messages.count - 1]
    #expect(observationMessage.role == .tool)
    #expect(observationMessage.toolCallId == "c1")
    #expect(observationMessage.content.text.contains("<claw-untrusted"))
    #expect(observationMessage.content.text.contains("page text"))
  }

  @Test func advertisedToolsRideEveryRequest() async throws {
    // given
    let definition = ToolDefinition(
      name: "web_fetch",
      description: "d",
      parameters: .object(["type": .string("object")]),
      egressClass: .none,
      riskLevel: .safe
    )
    let provider = SequenceProvider([okResponse()])
    let dispatcher = ScriptedDispatcher(definitions: [definition], respond: okOutcome())
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)

    // when
    _ = try await run(runtime)

    // then
    #expect(await provider.requests[0].tools.map(\.name) == ["web_fetch"])
  }

  @Test func liveObservationsFenceUnderTheToolsDeclaredLabel() async throws {
    // given — skill_load declares the "skills" label; its body must reach the wire under it
    let definition = ToolDefinition(
      name: "skill_load",
      description: "d",
      parameters: .object(["type": .string("object")]),
      egressClass: .none,
      riskLevel: .safe,
      fenceLabel: "skills"
    )
    let provider = SequenceProvider([
      toolCallResponse([ToolCall(id: "c1", name: "skill_load", argumentsJSON: #"{"name":"sum"}"#)]),
      okResponse(content: "done"),
    ])
    let dispatcher = ScriptedDispatcher(
      definitions: [definition],
      respond: okOutcome(content: "Keep it to three bullets.", ingestedUntrusted: false)
    )
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)

    // when
    let outcome = try await run(runtime)

    // then — fenced as "skills", and loading a skill leaves the session untainted
    let observationMessage = try #require(
      await provider.requests[1].messages.last { message in message.role == .tool }
    )
    #expect(observationMessage.content.text.contains("label=\"skills\""))
    #expect(observationMessage.content.text.contains("label=\"skill_load\"") == false)
    #expect(observationMessage.content.text.contains("Keep it to three bullets."))
    #expect(outcome.ingestedUntrusted == false)
  }

  @Test func maxTurnsCapStopsAndTells() async throws {
    // given — a provider that proposes tools forever; maxTurns 2
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal(id: "c1")]),
      toolCallResponse([fetchProposal(id: "c2")]),
      toolCallResponse([fetchProposal(id: "c3")]),
    ])
    let budget = RunBudget(
      maxInputTokens: 100_000,
      maxOutputTokens: 100,
      wallClockDeadlineSeconds: 180,
      retryBudget: 1,
      perRunUSD: 10,
      perDayUSD: 100,
      proactivePerDayUSD: 2.00,
      referenceUSDPerToken: 0.000_015,
      maxTurns: 2,
      maxToolCalls: 20
    )
    let runtime = makeRuntime(
      provider: provider,
      budget: budget,
      toolDispatcher: ScriptedDispatcher(respond: okOutcome())
    )

    // when
    let outcome = try await run(runtime)

    // then — no bonus round-trip: exactly maxTurns provider calls (§6.4)
    #expect(outcome.result == .budgetStopped(cap: "per-run turn"))
    #expect(await provider.requests.count == 2)
    #expect(outcome.ingestedUntrusted)  // executed observations still taint
  }

  @Test func midBatchToolCallCapDispatchesPrefixThenStops() async throws {
    // given (rev.1 L4) — one batch of 3 proposals with maxToolCalls 2
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal(id: "c1"), fetchProposal(id: "c2"), fetchProposal(id: "c3")])
    ])
    let budget = RunBudget(
      maxInputTokens: 100_000,
      maxOutputTokens: 100,
      wallClockDeadlineSeconds: 180,
      retryBudget: 1,
      perRunUSD: 10,
      perDayUSD: 100,
      proactivePerDayUSD: 2.00,
      referenceUSDPerToken: 0.000_015,
      maxTurns: 12,
      maxToolCalls: 2
    )
    let dispatcher = ScriptedDispatcher(respond: okOutcome())
    let runtime = makeRuntime(provider: provider, budget: budget, toolDispatcher: dispatcher)

    // when
    let outcome = try await run(runtime)

    // then — the under-cap prefix (c1, c2) dispatched; c3 ended the run
    #expect(outcome.result == .budgetStopped(cap: "per-run tool-call"))
    #expect(await dispatcher.records.map(\.call.id) == ["c1", "c2"])
  }

  @Test func blockedCallsCountTowardTheCap() async throws {
    // given — a dispatcher that blocks everything; maxToolCalls 2 (§6.4: blocked calls consumed
    // model+gate work)
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal(id: "c1"), fetchProposal(id: "c2"), fetchProposal(id: "c3")])
    ])
    let budget = RunBudget(
      maxInputTokens: 100_000,
      maxOutputTokens: 100,
      wallClockDeadlineSeconds: 180,
      retryBudget: 1,
      perRunUSD: 10,
      perDayUSD: 100,
      proactivePerDayUSD: 2.00,
      referenceUSDPerToken: 0.000_015,
      maxTurns: 12,
      maxToolCalls: 2
    )
    let dispatcher = ScriptedDispatcher { call, _ in
      ToolDispatchOutcome(
        observation: ToolObservation(
          callId: call.id,
          toolName: call.name,
          content: "blocked",
          status: .blockedArgs,
          ingestedUntrusted: false
        ),
        argsRedacted: "[REDACTED:secret-value]"
      )
    }
    let runtime = makeRuntime(provider: provider, budget: budget, toolDispatcher: dispatcher)

    // when
    let outcome = try await run(runtime)

    // then
    #expect(outcome.result == .budgetStopped(cap: "per-run tool-call"))
    #expect(outcome.ingestedUntrusted == false)  // blocked observations do not taint (§10)
  }

  @Test func inRunTaintAndPrivateFlagsFeedTheVeryNextGateContext() async throws {
    // given (rev.1 H1) — call 1 reads MEMORY.md (private), call 2's context must see BOTH flags
    let provider = SequenceProvider([
      toolCallResponse([
        ToolCall(id: "c1", name: "file_read", argumentsJSON: #"{"path":"MEMORY.md"}"#),
        fetchProposal(id: "c2"),
      ]),
      okResponse(content: "done"),
    ])
    let dispatcher = ScriptedDispatcher(respond: okOutcome(readPrivateData: true))
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)

    // when — assembly saw NO private data (over-cap scenario)
    _ = try await run(runtime, buildResult: makeBuildResult(hasPrivateDataAccess: false))

    // then
    let records = await dispatcher.records
    #expect(records[0].context.runIngestedUntrusted == false)
    #expect(records[0].context.runPrivateData == false)
    #expect(records[1].context.runIngestedUntrusted)
    #expect(records[1].context.runPrivateData)
  }

  @Test func perRunSpendAccumulatesAcrossRoundTrips() async throws {
    // given — a price table tuned to the estimator so ACCUMULATION is what trips (§15). With
    // maxOutputTokens 100 and $3_300/MTok: round-trip 1's preflight estimate (~102 tokens ≈ $0.34)
    // is under perRunUSD 0.50, so its provider call fires and records a real usage row. Round-trip
    // 2's own estimate (~146 tokens ≈ $0.48) is ALSO under 0.50, but recordedRunUSD (round-trip 1's
    // ~$0.05) + $0.48 ≈ $0.53 > 0.50, so the run-accumulated per-run check stops the run before the
    // second provider call.
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal()]),
      okResponse(),
    ])
    let priceTable = PriceTable(prices: [
      "gpt-4o": ModelPrice(inputUSDPerMTok: 3_300, outputUSDPerMTok: 3_300)
    ])
    let budget = RunBudget(
      maxInputTokens: 100_000,
      maxOutputTokens: 100,
      wallClockDeadlineSeconds: 180,
      retryBudget: 1,
      perRunUSD: 0.50,
      perDayUSD: 1_000,
      proactivePerDayUSD: 2.00,
      referenceUSDPerToken: 0.000_000_1
    )
    let runtime = makeRuntime(
      provider: provider,
      costResolver: makeCostResolver(priceTable: priceTable),
      budget: budget,
      toolDispatcher: ScriptedDispatcher(respond: okOutcome())
    )

    // when
    let outcome = try await run(runtime)

    // then — round-trip 1 recorded real cost; preflight 2 tripped the accumulated per-run check
    #expect(outcome.result == .budgetStopped(cap: "per-run spend"))
    #expect(await provider.requests.count == 1)
  }

  @Test func wireGrowthPastTheInputCapStopsBeforeTheNextProviderCall() async throws {
    // given — round-trip 1 proposes a tool call whose observation blows far past maxInputTokens
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal()]),
      okResponse(content: "never reached"),
    ])
    let hugeObservation = String(repeating: "x", count: 40_000)  // ≈12.5k estimated tokens
    let dispatcher = ScriptedDispatcher(respond: okOutcome(content: hugeObservation))
    let budget = RunBudget(
      maxInputTokens: 1_000,
      maxOutputTokens: 64,
      wallClockDeadlineSeconds: 60,
      retryBudget: 0,
      perRunUSD: 10,
      perDayUSD: 100,
      proactivePerDayUSD: 2,
      referenceUSDPerToken: 0.000_015
    )
    let runtime = makeRuntime(provider: provider, budget: budget, toolDispatcher: dispatcher)

    // when
    let outcome = try await run(runtime)

    // then — stopped offline at the input cap; the second provider call never happens
    #expect(outcome.result == .budgetStopped(cap: BudgetGate.perRunInputTokenCap))
    #expect(await provider.requests.count == 1)
    #expect(outcome.exchanges.count == 1)  // the executed exchange still rides the commit
  }

  @Test func aDeadlineAlreadyElapsedBeforeSendDegradesWithoutDebiting() async throws {
    // given — a whole-run deadline already elapsed at loop entry, so the first round never issues
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal()]),
      okResponse(),
    ])
    let dispatcher = ScriptedDispatcher { call, context in
      okOutcome()(call, context)
    }
    let budget = RunBudget(
      maxInputTokens: 100_000,
      maxOutputTokens: 100,
      wallClockDeadlineSeconds: 0,  // already elapsed
      retryBudget: 1,
      perRunUSD: 10,
      perDayUSD: 100,
      proactivePerDayUSD: 2.00,
      referenceUSDPerToken: 0.000_015
    )
    let runtime = makeRuntime(provider: provider, budget: budget, toolDispatcher: dispatcher)

    // when
    let outcome = try await run(runtime)

    // then — the request provably never issued (no provider call), so the degradation writes no row,
    // the same doctrine every other proven no-start follows
    let degraded = try requireDegraded(outcome.result)
    #expect(degraded.kind == .providerUnavailable)
    #expect(degraded.usage == nil)
    #expect(await provider.requests.isEmpty)
  }

  @Test func unknownToolAndMalformedArgsSurfaceAsObservationsViaDispatcher() async throws {
    // given — the dispatcher owns steps (0)/(1); the loop just forwards (§9.1)
    let provider = SequenceProvider([
      toolCallResponse([ToolCall(id: "c1", name: "nope", argumentsJSON: "{broken")]),
      okResponse(content: "recovered"),
    ])
    let dispatcher = ScriptedDispatcher { call, _ in
      ToolDispatchOutcome(
        observation: ToolObservation(
          callId: call.id,
          toolName: call.name,
          content: "Unknown tool nope.",
          status: .error,
          ingestedUntrusted: false
        ),
        argsRedacted: call.argumentsJSON
      )
    }
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)

    // when
    let outcome = try await run(runtime)

    // then — the run recovers with the error observation in history
    #expect(try requireCompleted(outcome.result).content == "recovered")
    #expect(outcome.exchanges[0].observations[0].status == .error)
  }
}
