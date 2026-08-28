import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite("Agent runtime route fallback")
struct AgentRuntimeFallbackTests {
  private func run(
    _ runtime: AgentRuntime,
    origin: RunOrigin = .interactive
  ) async throws -> TurnOutcome {
    try await runtime.runTurn(
      runId: 1,
      sessionId: 1,
      chatId: 1,
      buildResult: makeBuildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0,
      origin: origin
    )
  }

  @Test("a quota rejection on the primary completes on the fallback")
  func quotaSwitchesToFallback() async throws {
    // given
    let primary = StubProvider(.fail(.quotaLimited(retryAfterSeconds: nil)))
    let fallback = StubProvider(.respond(okResponse(content: "answered")))
    let runtime = makeRuntime(primary: primary, fallback: fallback)

    // when
    let outcome = try await run(runtime)

    // then
    let (content, _, _) = try requireCompleted(outcome.result)
    #expect(content == "answered")
    #expect(outcome.routeNotice == .switched(from: "primary-model", to: "fallback-model"))
    #expect(await fallback.calls == 1)
  }

  @Test("the fallback's usage row carries the fallback's identity and metered cost")
  func fallbackUsageIsAttributedToTheFallback() async throws {
    // given — the primary is an included-plan route, so a row minted through its accountant would
    // read as a confirmed $0 under the fallback's name.
    let primary = StubProvider(.fail(.quotaLimited(retryAfterSeconds: nil)))
    let fallback = StubProvider(.respond(okResponse(content: "answered")))
    let runtime = makeRuntime(primary: primary, fallback: fallback)

    // when
    let outcome = try await run(runtime)

    // then
    let (_, usage, _) = try requireCompleted(outcome.result)
    #expect(usage.model == "fallback-model")
    #expect(usage.costSource != .includedPlan)
    #expect(usage.costUSD > 0)
  }

  @Test("a failure the provider tagged as possibly-started never switches")
  func mayHaveStartedDoesNotSwitch() async throws {
    // given
    let started = ProviderFailure(
      cause: .quotaLimited(retryAfterSeconds: nil),
      accounting: .mayHaveStarted(observing: 7)
    )
    let primary = StubProvider(.failFailure(started))
    let fallback = StubProvider(.respond(okResponse(content: "never reached")))
    let runtime = makeRuntime(primary: primary, fallback: fallback)

    // when
    let outcome = try await run(runtime)

    // then
    let (kind, _) = try requireDegraded(outcome.result)
    #expect(kind == .quotaLimited(retryAfterSeconds: nil))
    #expect(outcome.routeNotice == nil)
    #expect(await fallback.calls == 0)
  }

  @Test("a retryable failure never switches")
  func retryableDoesNotSwitch() async throws {
    // given
    let primary = StubProvider(.fail(.retryable(status: 500, message: "boom")))
    let fallback = StubProvider(.respond(okResponse(content: "never reached")))
    let runtime = makeRuntime(primary: primary, fallback: fallback)

    // when
    let outcome = try await run(runtime)

    // then
    let (kind, _) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(outcome.routeNotice == nil)
    #expect(await fallback.calls == 0)
  }

  @Test("both routes failing reports the primary's degradation kind")
  func bothFailingReportsPrimaryKind() async throws {
    // given — the fallback's own cause maps to `.providerUnavailable`, so the assertion below can
    // only hold if the primary's kind is what reaches the owner.
    let primary = StubProvider(.fail(.quotaLimited(retryAfterSeconds: 42)))
    let fallback = StubProvider(.fail(.connectFailed(message: "down")))
    let runtime = makeRuntime(primary: primary, fallback: fallback)

    // when
    let outcome = try await run(runtime)

    // then
    let (kind, _) = try requireDegraded(outcome.result)
    #expect(kind == .quotaLimited(retryAfterSeconds: 42))
    #expect(await fallback.calls == 1)
  }

  @Test("a fallback deadline still reports the primary's degradation kind")
  func fallbackDeadlineReportsPrimaryKind() async throws {
    // given
    let primary = StubProvider(.fail(.quotaLimited(retryAfterSeconds: 42)))
    let fallback = StubProvider(
      .failInferenceCancellation(ProviderInferenceCancellation(observing: 0))
    )
    let runtime = makeRuntime(primary: primary, fallback: fallback)

    // when
    let outcome = try await run(runtime)

    // then
    let (kind, _) = try requireDegraded(outcome.result)
    #expect(kind == .quotaLimited(retryAfterSeconds: 42))
    #expect(outcome.attemptDiagnostics.failureCause == .deadline)
    #expect(await fallback.calls == 1)
  }

  @Test("a later round-trip failing on the fallback reports the fallback's own kind")
  func laterFailureOnTheFallbackReportsItsOwnKind() async throws {
    // given — the primary walls off on round-trip 1, then the fallback answers with a tool call and
    // refuses the credential on round-trip 2.
    let primary = StubProvider(.fail(.quotaLimited(retryAfterSeconds: nil)))
    let fallback = SequenceProvider(
      [toolCallResponse([fetchProposal()])],
      then: ProviderError.authenticationRequired
    )
    let runtime = makeRuntime(
      primary: primary,
      fallback: fallback,
      toolDispatcher: ScriptedDispatcher(respond: okOutcome())
    )

    // when
    let outcome = try await run(runtime)

    // then — the exhausted plan is stale news; the refused credential is what the owner can act on.
    let (kind, _) = try requireDegraded(outcome.result)
    #expect(kind == .authenticationRequired)
    #expect(await fallback.requests.count == 2)
  }

  @Test("a cooling primary is skipped and the turn starts on the fallback")
  func coolingPrimaryIsSkipped() async throws {
    // given
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: ScriptedClock { _ in })
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)
    let primary = StubProvider(.respond(okResponse(content: "must not be used")))
    let fallback = StubProvider(.respond(okResponse(content: "from fallback")))
    let runtime = makeRuntime(primary: primary, fallback: fallback, cooldown: cooldown)

    // when
    let outcome = try await run(runtime)

    // then
    let (content, _, _) = try requireCompleted(outcome.result)
    #expect(content == "from fallback")
    #expect(await primary.calls == 0)
  }

  @Test("the primary answering after its window lapsed tells the owner once")
  func lapsedPrimaryReportsRestored() async throws {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: clock)
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)
    try await clock.sleep(for: .seconds(901))
    let primary = StubProvider(.respond(okResponse(content: "answered")))
    let runtime = makeRuntime(primary: primary, fallback: nil, cooldown: cooldown)

    // when
    let outcome = try await run(runtime)

    // then
    _ = try requireCompleted(outcome.result)
    #expect(outcome.routeNotice == .restored(route: "primary-model"))
    #expect(await cooldown.isCooling() == false)
  }

  @Test("a scheduled run falls back on the same terms as an interactive turn")
  func proactiveOriginAlsoFallsBack() async throws {
    // given
    let primary = StubProvider(.fail(.quotaLimited(retryAfterSeconds: nil)))
    let fallback = StubProvider(.respond(okResponse(content: "answered")))
    let runtime = makeRuntime(primary: primary, fallback: fallback)

    // when
    let outcome = try await run(runtime, origin: .scheduled)

    // then
    let (content, _, _) = try requireCompleted(outcome.result)
    #expect(content == "answered")
  }

  @Test("a switch does not spend a round-trip from the turn's budget")
  func switchKeepsTheRoundTripBudget() async throws {
    // given — a one-round-trip turn: a switch that consumed the round would budget-stop instead.
    let primary = StubProvider(.fail(.quotaLimited(retryAfterSeconds: nil)))
    let fallback = StubProvider(.respond(okResponse(content: "answered")))
    let runtime = makeRuntime(
      primary: primary,
      fallback: fallback,
      budget: makeBudget(maxTurns: 1)
    )

    // when
    let outcome = try await run(runtime)

    // then
    let (content, _, _) = try requireCompleted(outcome.result)
    #expect(content == "answered")
  }

  @Test("a route switch is recorded in the audit log")
  func switchIsAudited() async throws {
    // given
    let audit = RecordingAuditLog()
    let primary = StubProvider(.fail(.quotaLimited(retryAfterSeconds: nil)))
    let fallback = StubProvider(.respond(okResponse(content: "answered")))
    let runtime = makeRuntime(primary: primary, fallback: fallback, auditLog: audit)

    // when
    _ = try await run(runtime)

    // then
    let recorded = audit.events.filter { event in
      event.action == .providerFallback
    }
    #expect(recorded.count == 1)
    #expect(recorded.first?.decision == "quotaLimited")
    #expect(recorded.first?.runId == 1)
  }

  @Test("no fallback configured degrades exactly as before")
  func singleRouteDegradesUnchanged() async throws {
    // given
    let primary = StubProvider(.fail(.quotaLimited(retryAfterSeconds: 42)))
    let runtime = makeRuntime(primary: primary, fallback: nil)

    // when
    let outcome = try await run(runtime)

    // then
    #expect(outcome.result == .degraded(.quotaLimited(retryAfterSeconds: 42), usage: nil))
    #expect(outcome.routeNotice == nil)
  }
}
