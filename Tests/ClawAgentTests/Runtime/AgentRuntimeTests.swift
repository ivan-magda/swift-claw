import ClawTestSupport
import Foundation
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
    let runtime = makeRuntime(provider: provider)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "hi")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — provider cost wins.
    let (content, usage, _) = try requireCompleted(outcome.result)

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
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "hello world")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — usage is estimated: prompt from the sent context, completion from the reply. Never a
    // zero row, so the hard daily token breaker can still account for it.
    let (content, usage, _) = try requireCompleted(outcome.result)

    #expect(content == "Hi!")
    // estimated from the prompt/reply — non-zero so the breaker can account for the turn
    #expect(usage.promptTokens > 0)
    #expect(usage.completionTokens > 0)
    #expect(usage.isEstimated == true)
    #expect(usage.costSource == .heuristic)
    #expect(usage.costUSD > 0)  // never a silent $0 (D1/F19)
  }

  @Test("a turn stamps the request with the namespaced session trace id")
  func turnStampsRequestWithSessionTraceId() async throws {
    // given
    let provider = StubProvider(.respond(okResponse(content: "hi")))
    let runtime = makeRuntime(provider: provider)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 42,
      chatId: 3,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "hi")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the request carries the OpenRouter-grouping id derived from the session id
    _ = try requireCompleted(outcome.result)
    #expect(await provider.lastRequest?.sessionId == "clawd-session-42")
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
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "hi")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    _ = try requireCompleted(outcome.result)
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
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "hi")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(outcome.result)

    #expect(kind == .outputTruncated)
    let recorded = try #require(usage)
    #expect(recorded.promptTokens == 50)
    #expect(recorded.completionTokens == 0)
    #expect(recorded.isEstimated == false)
  }

  @Test("the budget preflight stops before any provider call or typing")
  func budgetPreflightStopsBeforeAnyCall() async throws {
    // given — today's tokens already near the ceiling, so any estimate trips it.
    let provider = StubProvider(.respond(okResponse()))
    let typing = RecordingTyping()
    let runtime = makeRuntime(provider: provider, typing: typing)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "hi")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 999_999,
      todayUSD: 0
    )

    // then
    #expect(outcome.result == .budgetStopped(cap: BudgetGate.perDayTokenCap))
    #expect(await provider.calls == 0)
    #expect(await typing.calls == 0)
  }

  @Test("preflight prices the reserved output at the output rate, tripping a dearer-output model")
  func preflightPricesReservedOutputAtTheOutputRate() async throws {
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
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "hi")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — denied on the per-run USD cap, before the provider or typing fire.
    #expect(outcome.result == .budgetStopped(cap: BudgetGate.perRunSpendCap))
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
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "hi")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the gate allowed it through; the provider answered.
    _ = try requireCompleted(outcome.result)
    #expect(await provider.calls == 1)
  }

  @Test("a terminal provider error degrades without any debit")
  func terminalErrorDegradesWithoutDebit() async throws {
    // given
    let runtime = makeRuntime(provider: StubProvider(.fail(.terminal(status: 400, message: "bad"))))

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "hi")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    #expect(outcome.result == .degraded(.providerUnavailable, usage: nil))
  }

  @Test("exhausted retries degrade and debit the estimate (F28)")
  func retryableErrorDegradesAndDebitsTheEstimate() async throws {
    // given — the provider surfaces a retryable error after burning its retry budget.
    let runtime = makeRuntime(
      provider: StubProvider(.fail(.retryable(status: 503, message: "down")))
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "hello world")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — unlike a terminal error, a flapping provider is debited the pre-call estimate.
    let (kind, usage) = try requireDegraded(outcome.result)

    #expect(kind == .providerUnavailable)
    let recorded = try #require(usage)
    #expect(recorded.isEstimated == true)
    #expect(recorded.costSource == .heuristic)
    #expect(recorded.costUSD > 0)  // never a silent $0 (D1/F19)
  }

  @Test("the wall-clock deadline degrades and debits the estimate")
  func deadlineDegradesAndDebitsTheEstimate() async throws {
    // given — the provider hangs; a no-op sleep makes the 180s deadline fire immediately.
    let runtime = makeRuntime(
      provider: HangingProvider(),
      clock: ScriptedClock { _ in try? await Task.sleep(for: .milliseconds(1)) }
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "hello world")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — an estimated row: input estimate for "hello world" (4) + the reserved output cap.
    let (kind, usage) = try requireDegraded(outcome.result)

    #expect(kind == .providerUnavailable)
    let recorded = try #require(usage)
    #expect(recorded.isEstimated == true)
    #expect(recorded.costSource == .heuristic)
    #expect(recorded.costUSD > 0)  // never a silent $0 (D1/F19)
    #expect(recorded.promptTokens > 0)
    #expect(recorded.completionTokens == RunBudget.default.maxOutputTokens)
  }
}

// MARK: - Provider Replay State

extension AgentRuntimeTests {
  /// Deliberately not valid UTF-8: a runtime that treated the payload as text rather than opaque
  /// bytes would mangle it instead of handing it back unchanged.
  static let roundOneState = ProviderExchangeState(
    issuer: "openai-chatgpt-responses-v1:round-one",
    payload: Data([0x00, 0xC3, 0x28, 0xFF])
  )
  static let roundTwoState = ProviderExchangeState(
    issuer: "openai-chatgpt-responses-v1:round-two",
    payload: Data([0x80, 0xFE, 0x01])
  )

  @Test("every assistant anchor of a loop carries the state produced with it")
  func loopCarriesEachRoundsProviderState() async throws {
    // given — round one proposes a tool call with its own state; round two answers with another
    let provider = SequenceProvider([
      toolCallResponse(
        [fetchProposal()],
        content: "let me check",
        providerState: Self.roundOneState
      ),
      okResponse(content: "the page says hello", providerState: Self.roundTwoState),
    ])
    let dispatcher = ScriptedDispatcher(respond: okOutcome(content: "page text"))
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: makeBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the intermediate proposal keeps round one's state, the answer keeps round two's
    let completed = try requireCompleted(outcome.result)
    #expect(completed.providerState == Self.roundTwoState)
    #expect(outcome.exchanges.count == 1)
    #expect(outcome.exchanges[0].providerState == Self.roundOneState)

    // and the next round-trip replays round one's anchor state back to the route that minted it,
    // on the assistant message alone
    let secondRequest = try #require(await provider.requests.last)
    let anchor = try #require(secondRequest.messages.last { message in message.role == .assistant })
    #expect(anchor.providerState == Self.roundOneState)
    #expect(
      secondRequest.messages.filter { message in message.providerState != nil }.count == 1
    )
  }

  @Test("a route that mints no state leaves every anchor stateless")
  func aStatelessRouteProducesNoAnchorState() async throws {
    // given — the Chat Completions contract, which mints nothing
    let provider = SequenceProvider([
      toolCallResponse([fetchProposal()], content: "let me check"),
      okResponse(content: "done"),
    ])
    let dispatcher = ScriptedDispatcher(respond: okOutcome(content: "page text"))
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: makeBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    #expect(try requireCompleted(outcome.result).providerState == nil)
    #expect(outcome.exchanges.allSatisfy { exchange in exchange.providerState == nil })
    #expect(
      await provider.requests.allSatisfy { request in
        request.messages.allSatisfy { message in message.providerState == nil }
      }
    )
  }

  @Test("tool observations never carry replay state onto the wire")
  func toolObservationsNeverCarryState() async throws {
    // given
    let provider = SequenceProvider([
      toolCallResponse(
        [fetchProposal()],
        content: "let me check",
        providerState: Self.roundOneState
      ),
      okResponse(content: "done", providerState: Self.roundTwoState),
    ])
    let dispatcher = ScriptedDispatcher(respond: okOutcome(content: "page text"))
    let runtime = makeRuntime(provider: provider, toolDispatcher: dispatcher)

    // when
    _ = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: makeBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the fenced observation is untrusted input; replay material must never ride it, and the
    // issuer must never appear in the text a tool contributed
    let secondRequest = try #require(await provider.requests.last)
    for message in secondRequest.messages where message.role != .assistant {
      #expect(message.providerState == nil)
    }
    let toolRow = try #require(secondRequest.messages.last { message in message.role == .tool })
    #expect(toolRow.content.contains("round-one") == false)
  }
}
