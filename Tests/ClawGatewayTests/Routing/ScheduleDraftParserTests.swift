import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct ScheduleDraftParserTests {
  private func jsonResponse(_ content: String) -> ChatResponse {
    ChatResponse(content: content, finishReason: "stop", usage: nil, costFromProvider: nil)
  }

  private static let draftJSON = """
    {"label":"morning digest","prompt":"Summarize my unread items",\
    "schedule":{"kind":"weekdays","time":"07:00","timezone":"Europe/Berlin"}}
    """

  private static let expectedDraft = ScheduleDraft(
    label: "morning digest",
    prompt: "Summarize my unread items",
    schedule: DraftSchedule(kind: .weekdays, time: "07:00", timezone: "Europe/Berlin")
  )

  private struct Fixture {
    let parser: ScheduleDraftParser
    let sessionId: Int64
    let queue: DatabaseQueue
  }

  private func makeFixture(
    provider: any LLMProvider,
    budget: RunBudget = .default,
    structuredOutput: StructuredOutputMode = .off,
    costPolicy: LLMCostPolicy = .metered,
    clock: any Clock<Duration> = ContinuousClock()
  ) throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: "tg:dm:7",
        chatId: 7,
        userId: 7,
        text: "/schedule",
        isEdited: false,
        ts: Date()
      )
    )
    let parser = ScheduleDraftParser(
      roster: makeSingleRouteRoster(
        provider: provider,
        wireModel: "test-model",
        costPolicy: costPolicy
      ),
      usageStore: UsageStoreGRDB(writer: queue),
      budget: budget,
      costResolver: CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015),
      structuredOutput: structuredOutput,
      clock: clock,
      logger: TestLog.silent
    )
    return Fixture(parser: parser, sessionId: claim.sessionId ?? 0, queue: queue)
  }

  private func usageRowCount(_ fixture: Fixture) throws -> Int {
    try fixture.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage") ?? -1
    }
  }

  @Test func decodesASingleJSONObjectIntoADraft() async throws {
    // given
    let provider = SequenceProvider([jsonResponse(Self.draftJSON)])
    let fixture = try makeFixture(provider: provider)

    // when
    let result = await fixture.parser.parse(
      ownerText: "every weekday at 7am Berlin, summarize unread",
      sessionId: fixture.sessionId
    )

    // then
    #expect(result == .draft(Self.expectedDraft))
  }

  @Test func sendsOneBoundedSystemPromptedRequestWithOwnerTextAsData() async throws {
    // given
    let provider = SequenceProvider([jsonResponse(Self.draftJSON)])
    let fixture = try makeFixture(provider: provider)

    // when
    _ = await fixture.parser.parse(ownerText: "every weekday at 7am", sessionId: fixture.sessionId)

    // then — one call; system-authored prompt first; owner text is a plain user message; no
    // tools; the pinned output cap bounds the call in place of a preflight
    let requests = await provider.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.model == "test-model")
    #expect(request.messages.count == 2)
    #expect(request.messages[0].role == .system)
    #expect(request.messages[0].content.text == ScheduleDraftParser.systemPrompt)
    #expect(request.messages[1].role == .user)
    #expect(request.messages[1].content.text == "every weekday at 7am")
    #expect(request.tools.isEmpty)
    #expect(request.maxOutputTokens == ScheduleDraftParser.maxParseOutputTokens)
  }

  @Test func stripsAStrayCodeFenceBeforeDecoding() async throws {
    // given — models fence JSON despite instructions; the fence is cosmetic, not schema
    let fenced = "```json\n\(Self.draftJSON)\n```"
    let provider = SequenceProvider([jsonResponse(fenced)])
    let fixture = try makeFixture(provider: provider)

    // when / then
    #expect(
      await fixture.parser.parse(ownerText: "x", sessionId: fixture.sessionId)
        == .draft(Self.expectedDraft)
    )
  }

  @Test func rejectsNonJSONAndUnknownEnumValues() async {
    // given / when / then — strict decode: no guessing, no partial acceptance
    #expect(ScheduleDraftParser.decode("UNPARSEABLE") == .unparseable)
    #expect(ScheduleDraftParser.decode("Sure! Here is the plan…") == .unparseable)
    #expect(ScheduleDraftParser.decode("") == .unparseable)
    let badKind = """
      {"label":"x","prompt":"y","schedule":{"kind":"fortnightly","time":"07:00"}}
      """
    #expect(ScheduleDraftParser.decode(badKind) == .unparseable)
  }

  @Test func honorsTheUnparseableMarkerButDecodesADraftThatCarriesTheFlag() async {
    // given / when / then — the model's explicit {"unparseable": true} decline is unparseable,
    // while a real draft that also carries unparseable:false still decodes (the flag is not part
    // of the stored draft) — the shape json_schema mode returns for a valid request
    #expect(ScheduleDraftParser.decode(#"{"unparseable": true}"#) == .unparseable)
    #expect(
      ScheduleDraftParser.decode(
        #"{"unparseable": true, "label": null, "prompt": null, "schedule": null}"#
      ) == .unparseable
    )
    let flagged = """
      {"unparseable":false,"label":"morning digest","prompt":"Summarize my unread items",\
      "schedule":{"kind":"weekdays","time":"07:00","timezone":"Europe/Berlin"}}
      """
    #expect(ScheduleDraftParser.decode(flagged) == .draft(Self.expectedDraft))
  }

  @Test func offModeSendsNoResponseFormat() async throws {
    // given
    let provider = SequenceProvider([jsonResponse(Self.draftJSON)])
    let fixture = try makeFixture(provider: provider, structuredOutput: .off)

    // when
    _ = await fixture.parser.parse(ownerText: "every weekday at 7am", sessionId: fixture.sessionId)

    // then — today's behavior: the parse request carries no structured-output directive
    let request = try #require(await provider.requests.first)
    #expect(request.responseFormat == nil)
  }

  @Test func jsonSchemaModeConstrainsTheReplyToTheDraftSchema() async throws {
    // given
    let provider = SequenceProvider([jsonResponse(Self.draftJSON)])
    let fixture = try makeFixture(provider: provider, structuredOutput: .jsonSchema)

    // when
    _ = await fixture.parser.parse(ownerText: "every weekday at 7am", sessionId: fixture.sessionId)

    // then — the request pins the reply to the named schedule_draft schema
    let request = try #require(await provider.requests.first)
    guard case .jsonSchema(let name, _)? = request.responseFormat else {
      Issue.record("expected a json_schema response format")
      return
    }
    #expect(name == "schedule_draft")
  }

  @Test func providerFailureDegradesWithoutArming() async throws {
    // given — an empty script makes SequenceProvider throw a terminal ProviderError
    let provider = SequenceProvider([])
    let fixture = try makeFixture(provider: provider)

    // when / then — terminal: the provider generated and billed nothing, so no usage row
    #expect(
      await fixture.parser.parse(ownerText: "x", sessionId: fixture.sessionId)
        == .providerUnavailable
    )
    let rows = try await fixture.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage") ?? -1
    }
    #expect(rows == 0)
  }

  @Test func exhaustedRetriesDebitAnEstimate() async throws {
    // given — a brownout: `complete` retries and exhausts, throwing `.retryable` (not terminal)
    let fixture = try makeFixture(provider: RetryExhaustedProvider())

    // when
    let result = await fixture.parser.parse(
      ownerText: "every weekday at 7am",
      sessionId: fixture.sessionId
    )

    // then — parity with a turn's degradedForCaughtError (§15): the day cap sees an estimate so
    // repeated `/schedule` attempts during the brownout cannot re-issue the call with frozen totals
    #expect(result == .providerUnavailable)
    let estimated = try await fixture.queue.read { db in
      try Bool.fetchOne(db, sql: "SELECT is_estimated FROM provider_usage")
    }
    #expect(estimated == true)
  }

  @Test func dayCapDenialRefusesBeforeAnyProviderCall() async throws {
    // given — a day token ceiling the parse estimate alone exceeds
    let provider = SequenceProvider([jsonResponse(Self.draftJSON)])
    let tinyBudget = RunBudget(
      maxInputTokens: 100_000,
      maxOutputTokens: 4_096,
      wallClockDeadlineSeconds: 180,
      retryBudget: 3,
      perRunUSD: 0.50,
      perDayUSD: 10.00,
      proactivePerDayUSD: 2.00,
      referenceUSDPerToken: 0.000_015,
      dayTokenCeilingOverride: 10
    )
    let fixture = try makeFixture(provider: provider, budget: tinyBudget)

    // when
    let result = await fixture.parser.parse(
      ownerText: "every weekday at 7am",
      sessionId: fixture.sessionId
    )

    // then — denied by the offline gate; the provider was never called, nothing was spent
    #expect(result == .budgetDenied(cap: BudgetGate.perDayTokenCap))
    #expect(await provider.requests.isEmpty)
  }

  @Test func successfulParseRecordsARunlessUsageRow() async throws {
    // given
    let provider = SequenceProvider([jsonResponse(Self.draftJSON)])
    let fixture = try makeFixture(provider: provider)

    // when
    let result = await fixture.parser.parse(
      ownerText: "every weekday at 7am",
      sessionId: fixture.sessionId
    )

    // then — spend is durable (§6): one provider_usage row, attributed to the session, no run
    #expect(result == .draft(Self.expectedDraft))
    let row = try fixture.queue.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT run_id, session_id, model, is_estimated FROM provider_usage"
      )
    }
    let usageRow = try #require(row)
    #expect(usageRow["run_id"] == nil as Int64?)
    #expect(usageRow["session_id"] == fixture.sessionId)
    #expect(usageRow["model"] == "test-model")
  }

  @Test func deadlineWinsOverAHungProviderAndDebitsAnEstimate() async throws {
    // given — an instant deadline child (the injected sleep returns immediately) over a provider that
    // reached transport, so its cancel proves the attempt may have started and may be billing
    let fixture = try makeFixture(
      provider: HangingInferenceProvider(),
      clock: ScriptedClock { _ in }
    )

    // when
    let result = await fixture.parser.parse(
      ownerText: "every weekday at 7am",
      sessionId: fixture.sessionId
    )

    // then — the poller regains control and the maybe-billing request is debited as an estimate
    #expect(result == .providerUnavailable)
    let estimated = try await fixture.queue.read { db in
      try Bool.fetchOne(db, sql: "SELECT is_estimated FROM provider_usage")
    }
    #expect(estimated == true)
  }

  @Test func aProvenNoStartDeadlineLoserWritesNoUsageRow() async throws {
    // given — an instant deadline child over a provider cancelled before it reached transport, so its
    // `complete` surfaces the bare CancellationError that proves no start. A no-start owes nothing,
    // exactly as the turn path books it.
    let fixture = try makeFixture(provider: HangingProvider(), clock: ScriptedClock { _ in })

    // when
    let result = await fixture.parser.parse(
      ownerText: "every weekday at 7am",
      sessionId: fixture.sessionId
    )

    // then — the poller still sees the timeout degradation, but nothing is billed
    #expect(result == .providerUnavailable)
    #expect(try usageRowCount(fixture) == 0)
  }

  @Test func racedSuccessUnderTheDeadlineRecordsAuthoritativeUsage() async throws {
    // given — the deadline fires first, but the provider lands a real, usage-bearing reply anyway.
    // Its usage is authoritative, so the recorded row must be reconciled, not the timeout estimate.
    let response = ChatResponse(
      content: Self.draftJSON,
      finishReason: "stop",
      usage: ChatUsage(promptTokens: 11, completionTokens: 13, totalTokens: 24),
      costFromProvider: 0.004
    )
    let fixture = try makeFixture(
      provider: RacedSuccessProvider(response: response),
      clock: ScriptedClock { _ in try? await Task.sleep(for: .milliseconds(1)) }
    )

    // when
    let result = await fixture.parser.parse(
      ownerText: "every weekday at 7am",
      sessionId: fixture.sessionId
    )

    // then — the owner still sees the timeout, but the recorded row is authoritative (not estimated)
    #expect(result == .providerUnavailable)
    let row = try #require(
      try fixture.queue.read { db in
        try Row.fetchOne(
          db,
          sql: "SELECT is_estimated, completion_tokens FROM provider_usage"
        )
      }
    )
    #expect(row["is_estimated"] == false)
    #expect(row["completion_tokens"] == 13)
  }

  @Test func authenticationFailureReturnsTheTypedResultWithoutDebiting() async throws {
    // given — the credential is refused before any inference (a clean, not-started head)
    let fixture = try makeFixture(
      provider: SequenceProvider([], then: ProviderError.authenticationRequired)
    )

    // when
    let result = await fixture.parser.parse(ownerText: "x", sessionId: fixture.sessionId)

    // then — the router gets the typed outcome, not a collapsed providerUnavailable, and no row
    #expect(result == .authenticationRequired)
    #expect(try usageRowCount(fixture) == 0)
  }

  @Test func accessDenialReturnsTheTypedResultWithoutDebiting() async throws {
    // given
    let fixture = try makeFixture(provider: SequenceProvider([], then: ProviderError.accessDenied))

    // when / then
    #expect(
      await fixture.parser.parse(ownerText: "x", sessionId: fixture.sessionId) == .accessDenied
    )
    #expect(try usageRowCount(fixture) == 0)
  }

  @Test func quotaLimitReturnsTheRetryHintWithoutDebiting() async throws {
    // given
    let fixture = try makeFixture(
      provider: SequenceProvider([], then: ProviderError.quotaLimited(retryAfterSeconds: 15))
    )

    // when / then — the bounded hint rides the typed outcome; nothing was generated, nothing debited
    #expect(
      await fixture.parser.parse(ownerText: "x", sessionId: fixture.sessionId)
        == .quotaLimited(retryAfterSeconds: 15)
    )
    #expect(try usageRowCount(fixture) == 0)
  }

  @Test func cancelledParseWritesNoUsageRowAndStaysTheGenericOutage() async throws {
    // given — the command was cancelled once the call reached the provider, before anything billed
    let fixture = try makeFixture(provider: CancellingProvider())

    // when
    let result = await fixture.parser.parse(ownerText: "x", sessionId: fixture.sessionId)

    // then — a cancel is never an owner-facing outage escalation and bills nothing: the plain
    // unavailable result the run-cancellation UX suppresses, and no usage row (the arm's whole point)
    #expect(result == .providerUnavailable)
    #expect(try usageRowCount(fixture) == 0)
  }

  @Test func terminalRejectStaysTheGenericOutageWithoutDebiting() async throws {
    // given — a message-carrying terminal reject; its remote text must never reach a typed reply
    let fixture = try makeFixture(
      provider: SequenceProvider(
        [],
        then: ProviderError.terminal(status: 400, message: "internal provider detail")
      )
    )

    // when
    let result = await fixture.parser.parse(ownerText: "x", sessionId: fixture.sessionId)

    // then — the schedule twin of the turn's terminal reject: generic outage, no leaked text, no row
    #expect(result == .providerUnavailable)
    #expect(try usageRowCount(fixture) == 0)
  }

  @Test func includedPlanParseSkipsUSDButRecordsConfirmedZero() async throws {
    // given — a per-run USD ceiling the parse estimate exceeds, but a token ceiling it clears
    let budget = RunBudget(
      maxInputTokens: 100_000,
      maxOutputTokens: 4_096,
      wallClockDeadlineSeconds: 180,
      retryBudget: 3,
      perRunUSD: 0.000_000_1,
      perDayUSD: 10.00,
      proactivePerDayUSD: 2.00,
      referenceUSDPerToken: 0.000_015,
      dayTokenCeilingOverride: 1_000_000
    )

    // when — the metered route is denied on the USD gate the subscription route does not answer to
    let metered = try makeFixture(
      provider: SequenceProvider([jsonResponse(Self.draftJSON)]),
      budget: budget,
      costPolicy: .metered
    )
    let meteredResult = await metered.parser.parse(ownerText: "x", sessionId: metered.sessionId)

    // and — the included-plan route proceeds and records a confirmed (not guessed) zero
    let plan = try makeFixture(
      provider: SequenceProvider([jsonResponse(Self.draftJSON)]),
      budget: budget,
      costPolicy: .includedPlan
    )
    let planResult = await plan.parser.parse(ownerText: "x", sessionId: plan.sessionId)

    // then
    #expect(meteredResult == .budgetDenied(cap: BudgetGate.perRunSpendCap))
    #expect(planResult == .draft(Self.expectedDraft))
    let row = try #require(
      try plan.queue.read { db in
        try Row.fetchOne(db, sql: "SELECT cost_usd, cost_source FROM provider_usage")
      }
    )
    // A confirmed zero booked under its own source — not a guessed $0 — is what keeps the
    // never-a-silent-$0 rule satisfied while the USD gate is skipped.
    #expect(row["cost_usd"] == 0.0)
    #expect(row["cost_source"] == CostSource.includedPlan.rawValue)
  }

  @Test func includedPlanParseStillHonorsTheDayTokenCeiling() async throws {
    // given — a token ceiling the parse estimate alone exceeds; a subscription must not outrun it
    let budget = RunBudget(
      maxInputTokens: 100_000,
      maxOutputTokens: 4_096,
      wallClockDeadlineSeconds: 180,
      retryBudget: 3,
      perRunUSD: 0.50,
      perDayUSD: 10.00,
      proactivePerDayUSD: 2.00,
      referenceUSDPerToken: 0.000_015,
      dayTokenCeilingOverride: 10
    )
    let provider = SequenceProvider([jsonResponse(Self.draftJSON)])
    let fixture = try makeFixture(provider: provider, budget: budget, costPolicy: .includedPlan)

    // when
    let result = await fixture.parser.parse(ownerText: "x", sessionId: fixture.sessionId)

    // then — the token failsafe still binds under includedPlan, and the provider was never called
    #expect(result == .budgetDenied(cap: BudgetGate.perDayTokenCap))
    #expect(await provider.requests.isEmpty)
  }
}

/// Stands in for a provider whose retry budget is exhausted (repeated 429/5xx/transport): `complete`
/// surfaces `.retryable`, the same case `OpenAICompatibleProvider` throws once its retries run out.
private struct RetryExhaustedProvider: LLMProvider {
  func complete(request: ChatRequest) async throws -> ChatResponse {
    throw ProviderError.retryable(status: 429, message: "rate limited")
  }
}
