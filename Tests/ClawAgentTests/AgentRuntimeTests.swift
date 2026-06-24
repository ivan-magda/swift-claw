import Testing

@testable import ClawAgent
@testable import ClawCore

// MARK: - Unwrap helpers

private func requireCompleted(
  _ result: TurnResult
) throws -> (content: String, usage: ProviderUsage) {
  guard case .completed(let content, let usage) = result else {
    struct Mismatch: Error, CustomStringConvertible {
      let result: TurnResult
      var description: String { "expected TurnResult.completed, got \(result)" }
    }
    throw Mismatch(result: result)
  }
  return (content, usage)
}

private func requireDegraded(
  _ result: TurnResult
) throws -> (kind: DegradationKind, usage: ProviderUsage?) {
  guard case .degraded(let kind, let usage) = result else {
    struct Mismatch: Error, CustomStringConvertible {
      let result: TurnResult
      var description: String { "expected TurnResult.degraded, got \(result)" }
    }
    throw Mismatch(result: result)
  }
  return (kind, usage)
}

@Suite("AgentRuntime")
struct AgentRuntimeTests {
  @Test("a completed turn returns the content and the provider-reconciled usage")
  func completedTurnReturnsContentAndReconciledUsage() async throws {
    // given
    let provider = StubProvider(
      .respond(okResponse(content: "Hello there", costFromProvider: 0.0021))
    )
    let runtime = makeRuntime(provider: provider)

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hi")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then — provider cost wins.
    let (content, usage) = try requireCompleted(result)

    #expect(content == "Hello there")
    #expect(usage.costSource == .providerReturned)
    #expect(usage.costUSD == 0.0021)
    #expect(usage.isEstimated == false)
  }

  @Test("a completed turn whose provider omitted usage debits an estimated count, never zero")
  func completedTurnWithoutProviderUsageDebitsEstimate() async throws {
    // given — a provider (e.g. a local server) that returns content but no usage object.
    let runtime = makeRuntime(
      provider: StubProvider(
        .respond(okResponse(content: "Hi!", usage: nil, costFromProvider: nil))
      )
    )

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hello world")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then — usage is estimated: prompt from the sent context, completion from the reply. Never a
    // zero row, so the hard daily token breaker can still account for it.
    let (content, usage) = try requireCompleted(result)

    #expect(content == "Hi!")
    #expect(usage.promptTokens == 4)  // estimate for "hello world"
    #expect(usage.completionTokens == 2)  // estimate for "Hi!"
    #expect(usage.isEstimated == true)
    #expect(usage.costSource == .heuristic)
    #expect(usage.costUSD > 0)  // never a silent $0 (D1/F19)
  }

  @Test("a turn issues a typing pulse before the provider answers")
  func turnIssuesTypingPulseBeforeProviderAnswers() async throws {
    // given — the provider can't answer until typing has fired at least once (gate-released on the
    // first pulse), so the ordering is deterministic rather than a scheduler race.
    let gate = TypingReleaseGate()
    let typing = GatingTyping(gate: gate)
    let provider = GatedProvider(gate: gate, response: okResponse())
    let runtime = makeRuntime(provider: provider, typing: typing)

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hi")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    _ = try requireCompleted(result)
    #expect(await typing.calls >= 1)
  }

  @Test("empty content with finish_reason length is an output-truncation degradation")
  func emptyContentWithLengthFinishIsOutputTruncated() async throws {
    // given — the call returned, so real usage is debited even though the answer is empty.
    let response = okResponse(
      content: "",
      finishReason: "length",
      usage: ChatUsage(promptTokens: 50, completionTokens: 0, totalTokens: 50),
      costFromProvider: 0.0008
    )
    let runtime = makeRuntime(provider: StubProvider(.respond(response)))

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hi")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(result)

    #expect(kind == .outputTruncated)
    let recorded = try #require(usage)
    #expect(recorded.promptTokens == 50)
    #expect(recorded.completionTokens == 0)
    #expect(recorded.isEstimated == false)
  }

  @Test("the budget preflight stops before any provider call or typing")
  func budgetPreflightStopsBeforeAnyCall() async {
    // given — today's tokens already near the ceiling, so any estimate trips it.
    let provider = StubProvider(.respond(okResponse()))
    let typing = RecordingTyping()
    let runtime = makeRuntime(provider: provider, typing: typing)

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hi")],
      todayTokens: 999_999,
      todayUSD: 0
    )

    // then
    #expect(result == .budgetStopped(cap: "per-day token"))
    #expect(await provider.calls == 0)
    #expect(await typing.calls == 0)
  }

  @Test("preflight prices the reserved output at the output rate, tripping a dearer-output model")
  func preflightPricesReservedOutputAtTheOutputRate() async {
    // given — a model whose output token is far dearer than its input token. Folding the reserved
    // output into the prompt (the old bug) estimates ~$0.004 at the input rate and clears the $0.50
    // cap; pricing the 4096 reserved tokens at the output rate estimates ~$0.82 and must trip it.
    let priceTable = PriceTable(prices: [
      "dear-output": ModelPrice(inputUSDPerMTok: 1.0, outputUSDPerMTok: 200.0)
    ])
    let provider = StubProvider(.respond(okResponse()))
    let typing = RecordingTyping()
    let runtime = makeRuntime(
      provider: provider,
      typing: typing,
      costResolver: makeCostResolver(priceTable: priceTable),
      model: "dear-output"
    )

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hi")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then — denied on the per-run USD cap, before the provider or typing fire.
    #expect(result == .budgetStopped(cap: "per-run spend"))
    #expect(await provider.calls == 0)
    #expect(await typing.calls == 0)
  }

  @Test("preflight does not over-charge reserved output when the output rate is the cheaper one")
  func preflightDoesNotOverchargeReservedOutputAtTheInputRate() async throws {
    // given — the mirror case: input is the dear token. Pricing all 4098 tokens at the input rate
    // (the old bug) estimates ~$0.82 and would wrongly deny; pricing the 4096 reserved tokens at the
    // cheaper output rate estimates ~$0.004 and must let the run proceed to the provider.
    let priceTable = PriceTable(prices: [
      "dear-input": ModelPrice(inputUSDPerMTok: 200.0, outputUSDPerMTok: 1.0)
    ])
    let provider = StubProvider(.respond(okResponse()))
    let runtime = makeRuntime(
      provider: provider,
      costResolver: makeCostResolver(priceTable: priceTable),
      model: "dear-input"
    )

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hi")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the gate allowed it through; the provider answered.
    _ = try requireCompleted(result)
    #expect(await provider.calls == 1)
  }

  @Test("a terminal provider error degrades without any debit")
  func terminalErrorDegradesWithoutDebit() async {
    // given
    let runtime = makeRuntime(provider: StubProvider(.fail(.terminal(status: 400, message: "bad"))))

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hi")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    #expect(result == .degraded(.providerUnavailable, usage: nil))
  }

  @Test("exhausted retries degrade and debit the estimate (F28)")
  func retryableErrorDegradesAndDebitsTheEstimate() async throws {
    // given — the provider surfaces a retryable error after burning its retry budget.
    let runtime = makeRuntime(
      provider: StubProvider(.fail(.retryable(status: 503, message: "down")))
    )

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hello world")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then — unlike a terminal error, a flapping provider is debited the pre-call estimate.
    let (kind, usage) = try requireDegraded(result)

    #expect(kind == .providerUnavailable)
    let recorded = try #require(usage)
    #expect(recorded.isEstimated == true)
    #expect(recorded.costSource == .heuristic)
    #expect(recorded.costUSD > 0)  // never a silent $0 (D1/F19)
  }

  @Test("the wall-clock deadline degrades and debits the estimate")
  func deadlineDegradesAndDebitsTheEstimate() async throws {
    // given — the provider hangs; a no-op sleep makes the 180s deadline fire immediately.
    let runtime = makeRuntime(provider: HangingProvider(), sleep: { _ in })

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hello world")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then — an estimated row: input estimate for "hello world" (4) + the reserved output cap.
    let (kind, usage) = try requireDegraded(result)

    #expect(kind == .providerUnavailable)
    let recorded = try #require(usage)
    #expect(recorded.isEstimated == true)
    #expect(recorded.costSource == .heuristic)
    #expect(recorded.costUSD > 0)  // never a silent $0 (D1/F19)
    #expect(recorded.promptTokens == 4)
    #expect(recorded.completionTokens == RunBudget.default.maxOutputTokens)
  }
}
