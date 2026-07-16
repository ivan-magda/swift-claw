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
    // given — the provider hangs mid-flight (it reached transport, so it may be billing); a no-op
    // sleep makes the 180s deadline fire immediately.
    let runtime = makeRuntime(
      provider: HangingInferenceProvider(),
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

  @Test("a proven-no-start deadline loser writes no usage row")
  func deadlineWithAProvenNoStartWritesNoRow() async throws {
    // given — the provider hangs and is cancelled before it reaches transport, so its `complete`
    // surfaces the bare CancellationError that proves no start. A no-start owes nothing, exactly as
    // the non-deadline raw-cancellation path books it.
    let store = RecordingUsageStore()
    let runtime = makeRuntime(
      provider: HangingProvider(),
      usageStore: store,
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

    // then — the owner sees the timeout degradation, but nothing is billed
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(usage == nil)
    #expect(store.recorded.isEmpty)
  }

  @Test("a raced success under a won deadline books authoritative usage, not an estimate")
  func racedSuccessUnderTheDeadlineBooksAuthoritativeUsage() async throws {
    // given — the deadline fires first, but the provider finishes with a real, usage-bearing reply.
    // Its usage is authoritative, so the booked row must be the reconciled completed-call row — real
    // counts, provider cost — never the timeout estimate, while the owner still sees the degradation.
    let store = RecordingUsageStore()
    let response = okResponse(
      content: "landed under the deadline",
      usage: ChatUsage(promptTokens: 11, completionTokens: 13, totalTokens: 24),
      costFromProvider: 0.0021
    )
    let runtime = makeRuntime(
      provider: RacedSuccessProvider(response: response),
      usageStore: store,
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

    // then — the owner sees the timeout, but the row is authoritative: real counts and provider cost
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    let recorded = try #require(usage)
    #expect(recorded.isEstimated == false)
    #expect(recorded.costSource == .providerReturned)
    #expect(recorded.costUSD == 0.0021)
    #expect(recorded.promptTokens == 11)
    #expect(recorded.completionTokens == 13)
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

// MARK: - Provider policies: cost, identity, reservation

@Suite("AgentRuntime provider policies")
struct AgentRuntimePolicyTests {
  private static func userBuildResult(_ content: String = "hi") -> BuildResult {
    BuildResult(
      messages: [ChatMessage(role: .user, content: content)],
      ownerNotices: [],
      hasPrivateDataAccess: false
    )
  }

  @Test("an included-plan call records a confirmed zero under the qualified reference")
  func includedPlanProviderUsageWritesConfirmedZero() async throws {
    // given — a subscription route whose provider even reports dollars
    let store = RecordingUsageStore()
    let provider = StubProvider(.respond(okResponse(content: "hi", costFromProvider: 9.99)))
    let runtime = makeRuntime(
      provider: provider,
      model: "gpt-5",
      configuredReference: "openai-chatgpt/gpt-5",
      costPolicy: .includedPlan,
      usageStore: store
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: Self.userBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — cost is a confirmed zero, keyed on the qualified reference, and not an estimate since
    // the token counts were provider-returned
    let (_, usage, _) = try requireCompleted(outcome.result)
    #expect(usage.costUSD == 0)
    #expect(usage.costSource == .includedPlan)
    #expect(usage.isEstimated == false)
    #expect(usage.model == "openai-chatgpt/gpt-5")
    // the wire still carries the bare model
    #expect(await provider.lastRequest?.model == "gpt-5")
  }

  @Test(
    "an included-plan call with missing counts estimates tokens yet keeps cost a confirmed zero"
  )
  func includedPlanMissingUsageEstimatesTokensButCostStaysZero() async throws {
    // given — a subscription route whose provider omits the usage object
    let provider = StubProvider(.respond(okResponse(content: "hi", usage: nil)))
    let runtime = makeRuntime(
      provider: provider,
      model: "gpt-5",
      configuredReference: "openai-chatgpt/gpt-5",
      costPolicy: .includedPlan
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: Self.userBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the missing tokens are estimated (so isEstimated is true), but the confirmed zero and
    // its own source are the durable proof the $0 is not silent
    let (_, usage, _) = try requireCompleted(outcome.result)
    #expect(usage.isEstimated == true)
    #expect(usage.costUSD == 0)
    #expect(usage.costSource == .includedPlan)
  }

  @Test(
    "an included-plan call is not rejected by the USD cap, yet the token ceiling still stops it"
  )
  func includedPlanSkipsUSDButTokenCeilingStillStops() async throws {
    // given — a day already far over the USD cap
    let overUSD = RunBudget.default.perDayUSD * 5

    // when — a metered run is refused before any call
    let meteredProvider = StubProvider(.respond(okResponse()))
    let meteredOutcome = try await makeRuntime(provider: meteredProvider).runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: Self.userBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: overUSD
    )
    // then — the metered USD cap rejects, so the skip below is not vacuous
    guard case .budgetStopped = meteredOutcome.result else {
      Issue.record("expected the metered run to be budget-stopped, got \(meteredOutcome.result)")
      return
    }
    #expect(await meteredProvider.calls == 0)

    // when — the same day under the included-plan policy reaches the provider
    let planProvider = StubProvider(.respond(okResponse(content: "answer")))
    let planOutcome = try await makeRuntime(
      provider: planProvider,
      costPolicy: .includedPlan
    ).runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: Self.userBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: overUSD
    )
    // then — a subscription USD figure is not a gate
    _ = try requireCompleted(planOutcome.result)
    #expect(await planProvider.calls == 1)

    // when — but the hard daily token ceiling still binds under the subscription policy
    let tokenProvider = StubProvider(.respond(okResponse()))
    let tokenOutcome = try await makeRuntime(
      provider: tokenProvider,
      costPolicy: .includedPlan
    ).runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: Self.userBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: RunBudget.default.dayTokenCeiling,
      todayUSD: 0
    )
    // then — a token cap is not a USD cap, so it still stops the subscription call
    #expect(tokenOutcome.result == .budgetStopped(cap: BudgetGate.perDayTokenCap))
    #expect(await tokenProvider.calls == 0)
  }

  @Test("the replay-state reservation participates in the per-call input gate")
  func replayStateReservationEntersTheInputGate() async throws {
    // given — state whose two-tokens-per-byte reservation alone overshoots the input cap
    let stateBytes = 60_000

    // when — under text-only estimation the tiny wire clears the gate
    let textOnlyProvider = StubProvider(.respond(okResponse(content: "answer")))
    let textOnlyOutcome = try await makeRuntime(provider: textOnlyProvider).runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: buildResultCarryingState(bytes: stateBytes),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )
    // then — text-only reserves nothing for the bytes, so the call goes out
    _ = try requireCompleted(textOnlyOutcome.result)
    #expect(await textOnlyProvider.calls == 1)

    // when — the same wire under the replay-state reservation
    let reservedProvider = StubProvider(.respond(okResponse()))
    let reservedOutcome = try await makeRuntime(
      provider: reservedProvider,
      reservationPolicy: .chatGPTReplayState
    ).runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: buildResultCarryingState(bytes: stateBytes),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )
    // then — replay state cannot bypass the token gate; the provider is never reached
    #expect(reservedOutcome.result == .budgetStopped(cap: BudgetGate.perRunInputTokenCap))
    #expect(await reservedProvider.calls == 0)
  }

  @Test("the reservation inflates the estimated prompt of a missing-usage row")
  func replayStateReservationInflatesTheMissingUsageEstimate() async throws {
    // given — a small state that does not trip the input gate, and a provider that omits usage
    let stateBytes = 1_000
    let expectedReservation = 2 * stateBytes + 256

    func recordedPrompt(reservation: LLMInputReservationPolicy) async throws -> Int {
      let outcome = try await makeRuntime(
        provider: StubProvider(.respond(okResponse(content: "hi", usage: nil))),
        reservationPolicy: reservation
      ).runTurn(
        runId: 1,
        sessionId: 2,
        chatId: 3,
        buildResult: buildResultCarryingState(bytes: stateBytes),
        sessionTainted: false,
        sessionHasPrivateData: false,
        todayTokens: 0,
        todayUSD: 0
      )
      return try requireCompleted(outcome.result).usage.promptTokens
    }

    // when
    let textOnlyPrompt = try await recordedPrompt(reservation: .textOnly)
    let reservedPrompt = try await recordedPrompt(reservation: .chatGPTReplayState)

    // then — the difference is exactly the reservation the policy charges for those bytes
    #expect(reservedPrompt - textOnlyPrompt == expectedReservation)
  }
}

// MARK: - Conservative failure and cancellation accounting

@Suite("AgentRuntime failure accounting")
struct AgentRuntimeFailureAccountingTests {
  private static func userBuildResult() -> BuildResult {
    BuildResult(
      messages: [ChatMessage(role: .user, content: "hi")],
      ownerNotices: [],
      hasPrivateDataAccess: false
    )
  }

  private static func runDegraded(
    _ outcome: StubProvider.Outcome,
    store: RecordingUsageStore
  ) async throws -> (kind: DegradationKind, usage: ProviderUsage?) {
    let outcome = try await makeRuntime(
      provider: StubProvider(outcome),
      usageStore: store
    ).runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: userBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )
    return try requireDegraded(outcome.result)
  }

  @Test("a budget-exhausted clean failure — notStarted — writes no usage row")
  func notStartedFailureWritesNoUsageRow() async throws {
    // given — the shape a budget-exhausted 5xx takes: a retryable cause, but proven not-started
    let store = RecordingUsageStore()

    // when
    let (kind, usage) = try await Self.runDegraded(
      .failFailure(
        ProviderFailure(cause: .retryable(status: 503, message: "x"), accounting: .notStarted)
      ),
      store: store
    )

    // then — the disposition, not the cause class, decides: nothing was generated, nothing is owed
    #expect(kind == .providerUnavailable)
    #expect(usage == nil)
    #expect(store.recorded.isEmpty)
  }

  @Test("a may-have-started failure writes a conservative row bounded below by the observed count")
  func mayHaveStartedFailureWritesConservativeRow() async throws {
    // given — an observed lower bound far above the local output reservation
    let observed = RunBudget.default.maxOutputTokens + 5_000
    let store = RecordingUsageStore()

    // when
    let (_, usage) = try await Self.runDegraded(
      .failFailure(
        ProviderFailure(
          cause: .retryable(status: nil, message: "lost"),
          accounting: .mayHaveStarted(observing: observed)
        )
      ),
      store: store
    )

    // then — completion is the larger of the reservation and the observed estimate
    let row = try #require(usage)
    #expect(row.isEstimated)
    #expect(row.completionTokens == observed)
  }

  @Test("a may-have-started failure below the reservation still reserves the local output cap")
  func mayHaveStartedBelowReservationKeepsTheOutputCap() async throws {
    // given — a small observed count
    let store = RecordingUsageStore()

    // when
    let (_, usage) = try await Self.runDegraded(
      .failFailure(
        ProviderFailure(
          cause: .retryable(status: nil, message: "lost"),
          accounting: .mayHaveStarted(observing: 3)
        )
      ),
      store: store
    )

    // then — the output reservation wins the max
    #expect(try #require(usage).completionTokens == RunBudget.default.maxOutputTokens)
  }

  @Test("raw task cancellation writes nothing")
  func rawCancellationWritesNothing() async throws {
    // given
    let store = RecordingUsageStore()

    // when
    let (kind, usage) = try await Self.runDegraded(.failCancellation, store: store)

    // then
    #expect(kind == .providerUnavailable)
    #expect(usage == nil)
    #expect(store.recorded.isEmpty)
  }

  @Test("typed inference cancellation writes conservative usage")
  func inferenceCancellationWritesConservativeUsage() async throws {
    // given
    let store = RecordingUsageStore()

    // when
    let (_, usage) = try await Self.runDegraded(
      .failInferenceCancellation(ProviderInferenceCancellation(observing: 7)),
      store: store
    )

    // then — the model may have been asked, so a conservative row is owed on the degraded result
    let row = try #require(usage)
    #expect(row.isEstimated)
    #expect(row.completionTokens == RunBudget.default.maxOutputTokens)
  }

  @Test("an authentication failure carries the auth kind through and writes no usage row")
  func authenticationFailureCarriesTheAuthKindAndWritesNoRow() async throws {
    // given
    let store = RecordingUsageStore()

    // when
    let (kind, usage) = try await Self.runDegraded(.fail(.authenticationRequired), store: store)

    // then — the runtime does NOT collapse it into the generic outage; nothing was generated
    #expect(kind == .authenticationRequired)
    #expect(usage == nil)
    #expect(store.recorded.isEmpty)
  }

  @Test("an access denial carries its own kind and writes no usage row")
  func accessDenialCarriesItsOwnKindAndWritesNoRow() async throws {
    // given
    let store = RecordingUsageStore()

    // when
    let (kind, usage) = try await Self.runDegraded(.fail(.accessDenied), store: store)

    // then
    #expect(kind == .accessDenied)
    #expect(usage == nil)
    #expect(store.recorded.isEmpty)
  }

  @Test("a quota throttle carries the provider's retry hint and writes no usage row")
  func quotaThrottleCarriesTheRetryHintAndWritesNoRow() async throws {
    // given
    let store = RecordingUsageStore()

    // when
    let (kind, usage) = try await Self.runDegraded(
      .fail(.quotaLimited(retryAfterSeconds: 42)),
      store: store
    )

    // then — the bounded hint rides the kind so the gateway can name it
    #expect(kind == .quotaLimited(retryAfterSeconds: 42))
    #expect(usage == nil)
    #expect(store.recorded.isEmpty)
  }

  @Test("rejected replay state carries the invalid-state kind and writes no usage row")
  func rejectedReplayStateCarriesTheInvalidStateKind() async throws {
    // given
    let store = RecordingUsageStore()

    // when
    let (kind, usage) = try await Self.runDegraded(.fail(.invalidProviderState), store: store)

    // then
    #expect(kind == .invalidProviderState)
    #expect(usage == nil)
    #expect(store.recorded.isEmpty)
  }

  @Test("a message-carrying terminal reject stays the generic outage, never a typed kind")
  func terminalRejectStaysTheGenericOutage() async throws {
    // given — a cause whose payload is remote text; it must never reach a typed owner reply
    let store = RecordingUsageStore()

    // when
    let (kind, usage) = try await Self.runDegraded(
      .fail(.terminal(status: 400, message: "internal provider detail")),
      store: store
    )

    // then — generic outage, no row (proven not-started), and no remote text carried on the kind
    #expect(kind == .providerUnavailable)
    #expect(usage == nil)
    #expect(store.recorded.isEmpty)
  }

  @Test("a notStarted failure after a tool round keeps only the round's recorded row")
  func notStartedAfterAToolRoundKeepsOnlyTheRecordedRow() async throws {
    // given — a first round that proposes a tool (recording usage), then a not-started failure
    let store = RecordingUsageStore()
    let provider = SequenceProvider(
      [toolCallResponse([fetchProposal()], content: "checking")],
      then: ProviderFailure(cause: .retryable(status: 503, message: "x"), accounting: .notStarted)
    )
    let runtime = makeRuntime(
      provider: provider,
      toolDispatcher: ScriptedDispatcher(respond: okOutcome(ingestedUntrusted: false)),
      usageStore: store
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: Self.userBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the failed second round adds no row; only the first round's usage stands
    let (kind, _) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(store.recorded.count == 1)
    #expect(await provider.requests.count == 2)
  }
}
