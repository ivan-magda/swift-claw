import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite("AgentRuntime")
struct AgentRuntimeTests {
  @Test("a completed turn returns the content and the provider-reconciled usage")
  func completedTurnReturnsContentAndReconciledUsage() async throws {
    // given
    let provider = StubProvider(
      .respond(okResponse(content: "Hello there", costFromProvider: 0.0021))
    )
    let typing = RecordingTyping()
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

    // then — provider cost wins; typing was issued at least once.
    guard case .completed(let content, let usage) = result else {
      Issue.record("expected .completed, got \(result)")
      return
    }

    #expect(content == "Hello there")
    #expect(usage.costSource == .providerReturned)
    #expect(usage.costUSD == 0.0021)
    #expect(usage.isEstimated == false)
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
    guard case .degraded(let kind, let usage) = result else {
      Issue.record("expected .degraded, got \(result)")
      return
    }

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
    #expect(result == .budgetStopped(cap: "per-day token ceiling"))
    #expect(await provider.calls == 0)
    #expect(await typing.calls == 0)
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
    guard case .degraded(let kind, let usage) = result else {
      Issue.record("expected .degraded, got \(result)")
      return
    }

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
    guard case .degraded(let kind, let usage) = result else {
      Issue.record("expected .degraded, got \(result)")
      return
    }

    #expect(kind == .providerUnavailable)
    let recorded = try #require(usage)
    #expect(recorded.isEstimated == true)
    #expect(recorded.costSource == .heuristic)
    #expect(recorded.costUSD > 0)  // never a silent $0 (D1/F19)
    #expect(recorded.promptTokens == 4)
    #expect(recorded.completionTokens == RunBudget.default.maxOutputTokens)
  }
}
